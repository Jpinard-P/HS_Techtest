-- Identifies each unbroken run of available nights per listing, so the mart
-- can answer "what is the longest stay this listing could actually take?"
-- without every analyst having to write their own gaps-and-islands query.
--
-- The islands trick: for rows ordered by date, a dense sequence over the whole
-- listing minus a dense sequence over just the available days is constant for
-- as long as availability doesn't flip. That constant is the run id.

with calendar as (

    select
        listing_id,
        calendar_date,
        is_available,
        maximum_nights
    from {{ ref('stg_calendar') }}

),

islanded as (

    select
        *,
        row_number() over (partition by listing_id order by calendar_date)
        - row_number() over (partition by listing_id, is_available order by calendar_date)
            as island_key
    from calendar

),

runs as (

    select
        listing_id,
        island_key,
        min(calendar_date)  as run_start_date,
        max(calendar_date)  as run_end_date,
        count(*)            as run_nights,

        -- maximum_nights is a per-day column and varies across a listing's
        -- calendar (though within no single run of this extract), so the cap
        -- is the strictest value in the run, not the first or last. For a
        -- stay spanning the whole run that is exact; for a stay spanning part
        -- of one it is conservative, since only the days the stay covers
        -- could bind. With no within-run variation today, the two readings
        -- agree on every run.
        min(maximum_nights) as binding_maximum_nights

    from islanded
    where is_available
    group by 1, 2

),

final as (

    select
        listing_id,
        island_key as availability_run_key,
        run_start_date,
        run_end_date,
        run_nights,
        binding_maximum_nights,

        -- The longest bookable stay inside this run: you cannot stay longer
        -- than the run is open, nor longer than the owner permits.
        -- minimum_nights is deliberately not applied (problem 3 asks for
        -- availability windows and maximum limits only), and it is not a
        -- no-op: 58 runs in this extract are shorter than their own minimum,
        -- so a stay of this length may not actually be offerable. The mart
        -- carries minimum_nights per day for that check.
        least(run_nights, binding_maximum_nights) as max_bookable_nights,

        -- A run touching either end of the loaded calendar is a lower bound,
        -- not a measurement: the vacancy may continue beyond what was loaded.
        run_start_date = (select min(calendar_date) from {{ ref('stg_calendar') }}) as starts_at_calendar_start,
        run_end_date   = (select max(calendar_date) from {{ ref('stg_calendar') }}) as ends_at_calendar_end

    from runs

)

select * from final
