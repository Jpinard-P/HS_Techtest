{{
    config(
        materialized = 'incremental',
        unique_key = ['listing_id', 'calendar_date'],
        incremental_strategy = 'delete+insert',
        on_schema_change = 'append_new_columns'
    )
}}

-- The reporting-layer mart: one row per listing per calendar day.
--
-- MATERIALIZATION: incremental, and the reason is retention rather than speed.
--
-- An availability calendar is a rolling forward window: the source publishes
-- roughly the next year per listing, and each day it drops the day that has
-- passed and adds one at the far end. A table rebuilt from scratch therefore
-- holds only what the source still publishes, and every day that has aged out
-- of the feed is gone. Year-over-year revenue -- the analysis this mart exists
-- for -- needs the days the feed has already forgotten. Incremental with a
-- (listing_id, calendar_date) key accumulates that history instead.
--
-- The whole published window is restated on every run, not just its new far
-- edge. Future days are mutable: a night that is free today is booked
-- tomorrow, and its price moves until it sells. Appending only unseen dates
-- would freeze each day at whatever it looked like when first seen, so the
-- table would fill with stale availability and understated revenue -- silently,
-- since the row count would keep growing exactly as expected. delete+insert on
-- the composite key restates the window in place, and days outside it are left
-- untouched.
--
-- 'delete+insert' rather than 'merge' because merge requires a newer DuckDB
-- than this project pins; the semantics needed here are identical.
--
-- The derived columns stay correct under this scheme because the intermediates
-- feeding them are views over the full staging models, so availability runs and
-- amenity versions are always computed against everything the source currently
-- publishes rather than against the incremental slice. That is also the limit
-- of the design: at warehouse scale those intermediates become the expensive
-- step, and the next move is to materialize them and partition this table on
-- calendar_date so the restatement predicate can prune.
--
-- Grain is the calendar, not the listing. Every listing-day that the source
-- calendar knows about survives into this table, including days belonging to
-- listing 276450, which has 365 calendar days and 2 amenity changes but no row
-- in LISTINGS. Joining listings inwards would drop it, and dropping it moves
-- the answer to the amenity-revenue question from 21.2% to 22.1% -- a real
-- revenue difference caused by a join type. Its descriptive columns are NULL
-- and has_listing_record marks it, so it can be excluded deliberately rather
-- than by accident.

with calendar as (

    select * from {{ ref('stg_calendar') }}

),

listings as (

    select * from {{ ref('stg_listings') }}

),

amenity_versions as (

    select * from {{ ref('int_amenities_versioned') }}

),

availability_runs as (

    select * from {{ ref('int_calendar_days_grouped_into_availability_runs') }}

),

reservations as (

    select * from {{ ref('int_calendar_days_collapsed_to_reservations') }}

),

-- The loaded calendar does not begin or end on month boundaries, so its first
-- and last months are only partly covered (currently 20 days of July 2021 and
-- 11 of July 2022). This mart exists to support period-over-period analysis,
-- which is exactly the analysis those stubs break -- a part-covered month
-- always looks like a collapse in revenue next to a full one.
--
-- Coverage is measured from the data on every run rather than compared against
-- fixed dates, so extending the calendar corrects these flags automatically.
-- Each day carries the completeness of its month so a comparison can exclude
-- the partial ones on purpose.
month_coverage as (

    select
        date_trunc('month', calendar_date) as month_start_date,
        count(distinct calendar_date)      as days_covered,
        datediff(
            'day',
            date_trunc('month', min(calendar_date)),
            date_trunc('month', min(calendar_date)) + interval 1 month
        ) as days_in_month
    from calendar
    group by 1

),

joined as (

    select
        calendar.listing_id,
        calendar.calendar_date,

        listings.listing_id is not null as has_listing_record,

        -- Date attributes, so common groupings don't need a date spine.
        date_trunc('month', calendar.calendar_date)   as month_start_date,
        year(calendar.calendar_date)                  as calendar_year,
        month(calendar.calendar_date)                 as calendar_month,
        dayname(calendar.calendar_date)               as day_name,
        dayofweek(calendar.calendar_date) in (0, 6)   as is_weekend,
        month_coverage.days_covered = month_coverage.days_in_month as is_complete_month,
        month_coverage.days_covered                   as days_of_month_in_calendar,

        -- Listing attributes, denormalised. The reporting layer slices daily
        -- revenue by neighbourhood and property type constantly; making that a
        -- join every time is how a stakeholder ends up with an inner join and
        -- a quietly shorter table.
        listings.listing_name,
        listings.host_id,
        listings.neighborhood,
        listings.property_type,
        listings.room_type,
        listings.accommodates,
        listings.bedrooms,
        listings.beds,

        -- Occupancy. is_reserved is the inverse of is_available and they agree
        -- on every row (a test enforces it); both are exposed because
        -- occupancy reads naturally as a positive and vacancy as a negative,
        -- and an analyst inverting a flag by hand is an easy sign error.
        calendar.is_available,
        not calendar.is_available as is_reserved,
        calendar.reservation_id,
        reservations.reservation_nights,
        reservations.first_night as reservation_first_night,
        reservations.last_night  as reservation_last_night,

        -- Money. nightly_price is what the listing asked for that night,
        -- whether or not anyone booked it; revenue is what it actually earned.
        -- Summing nightly_price gives potential revenue and would overstate
        -- takings by roughly the vacancy rate, so the two are named apart
        -- rather than left to a WHERE clause the analyst has to remember.
        calendar.calendar_price as nightly_price,
        case when calendar.is_available then 0 else calendar.calendar_price end as revenue,

        calendar.minimum_nights,
        calendar.maximum_nights,

        -- Bookability. Carried at day grain so "the longest stay this listing
        -- could take" is a MAX over the days rather than a gaps-and-islands
        -- query each analyst rewrites. NULL on reserved nights: a booked night
        -- is not part of any vacancy.
        availability_runs.availability_run_key,
        availability_runs.run_start_date       as available_run_start_date,
        availability_runs.run_end_date         as available_run_end_date,
        availability_runs.run_nights           as available_run_nights,
        availability_runs.max_bookable_nights,
        coalesce(availability_runs.starts_at_calendar_start, false)
            or coalesce(availability_runs.ends_at_calendar_end, false)
            as available_run_touches_calendar_edge,

        -- Amenities as they stood on this specific day, not as they stand now.
        amenity_versions.amenities,
        amenity_versions.amenity_count,
        amenity_versions.version_number as amenity_version_number,
        amenity_versions.changed_at     as amenities_effective_from,

        list_contains(amenity_versions.amenities, 'Air conditioning') as has_air_conditioning,
        list_contains(amenity_versions.amenities, 'Lockbox')          as has_lockbox,
        list_contains(amenity_versions.amenities, 'First aid kit')    as has_first_aid_kit

    from calendar

    left join listings
        on listings.listing_id = calendar.listing_id

    left join month_coverage
        on month_coverage.month_start_date = date_trunc('month', calendar.calendar_date)

    -- As-of join. The half-open validity range means exactly one version can
    -- match a given instant; a day is attributed to whichever version was in
    -- force at midnight when it began.
    left join amenity_versions
        on  amenity_versions.listing_id = calendar.listing_id
        and cast(calendar.calendar_date as timestamp) >= amenity_versions.valid_from
        and cast(calendar.calendar_date as timestamp) <  amenity_versions.valid_to

    left join availability_runs
        on  availability_runs.listing_id = calendar.listing_id
        and calendar.calendar_date between availability_runs.run_start_date
                                       and availability_runs.run_end_date

    left join reservations
        on  reservations.listing_id     = calendar.listing_id
        and reservations.reservation_id = calendar.reservation_id

)

select * from joined
