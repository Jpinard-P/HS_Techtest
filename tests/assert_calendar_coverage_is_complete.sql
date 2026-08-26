-- Every listing in the calendar covers the same unbroken date range
-- (2021-07-12 to 2022-07-11), one row per day. Occupancy and revenue rates
-- divide by a day count, so a listing with missing days would quietly report
-- a rate against a shorter denominator rather than fail.

with per_listing as (

    select
        listing_id,
        count(*)                as day_count,
        min(calendar_date)      as first_date,
        max(calendar_date)      as last_date,
        count(distinct calendar_date) as distinct_days
    from {{ ref('stg_calendar') }}
    group by 1

),

calendar_bounds as (

    select
        min(first_date) as calendar_start,
        max(last_date)  as calendar_end
    from per_listing

)

select per_listing.*
from per_listing
cross join calendar_bounds
where per_listing.first_date <> calendar_bounds.calendar_start
   or per_listing.last_date <> calendar_bounds.calendar_end
   -- contiguous: as many rows as there are days in the span, no gaps or dupes
   or per_listing.day_count <> datediff('day', per_listing.first_date, per_listing.last_date) + 1
   or per_listing.distinct_days <> per_listing.day_count
