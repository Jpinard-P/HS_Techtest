-- Problem 2: average price increase for each neighborhood between
-- 2021-07-12 and 2022-07-11.
--
-- Published check: Back Bay holds a single listing, 10813, whose price rises
-- $106 -> $150, so the neighborhood average is $44. This query returns $44.
--
-- Those two dates are parameters of *this question*, not properties of the
-- data. They are pinned as literals in the CTE below rather than derived from
-- MIN and MAX of the calendar, because the two are different things that
-- happen to coincide in the current extract. Deriving them would mean that
-- loading one more day of calendar silently changes the answer to a question
-- that named its own dates -- and nobody would see it happen. (They were
-- once project-level vars; literals won because the question names its own
-- dates, so the query should too, in the file a reader is already looking
-- at.)
--
-- Two further modelling notes:
--
--   * The measure is nightly_price, not revenue. This is a question about
--     asking prices, and using revenue would score every night the listing sat
--     empty as a price of zero.
--
--   * The average is taken per listing first and then across listings, so each
--     listing counts once regardless of how many nights it has. Averaging the
--     daily rows directly would weight listings by their calendar coverage.
--
-- The has_listing_record guard excludes any listing with calendar days but
-- no descriptive record, which a neighborhood cut cannot place. In the
-- current build it excludes nothing: the one such listing, 276450, has its ID
-- recovered in stg_listings and lands in Roxbury -- which is why Roxbury
-- averages 13 listings (-$6.15) rather than 12 ($0.00). The guard stays so
-- the next orphan is excluded here deliberately and visibly, not silently by
-- a join.

with comparison_dates as (

    select
        date '2021-07-12' as start_date,
        date '2022-07-11' as end_date

),

listing_endpoints as (

    select
        fct.listing_id,
        fct.neighborhood,
        max(case when fct.calendar_date = dates.start_date then fct.nightly_price end) as price_at_start,
        max(case when fct.calendar_date = dates.end_date   then fct.nightly_price end) as price_at_end
    from {{ ref('listing_days') }} as fct
    cross join comparison_dates as dates
    where fct.has_listing_record
    group by 1, 2

)

select
    neighborhood,
    count(*) as listings,
    round(avg(price_at_end - price_at_start), 2) as avg_price_increase,
    round(avg(price_at_start), 2) as avg_price_at_start,
    round(avg(price_at_end), 2)   as avg_price_at_end
from listing_endpoints

-- A listing missing a price on either named date cannot contribute a delta.
-- Excluding it explicitly beats letting AVG skip the NULL, which would leave
-- the listing counted in the denominator of count(*) but not in the average.
where price_at_start is not null
  and price_at_end is not null

group by 1
order by avg_price_increase desc
