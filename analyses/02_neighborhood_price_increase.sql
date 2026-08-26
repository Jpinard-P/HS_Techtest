-- Problem 2: average price increase for each neighborhood between
-- 2021-07-12 and 2022-07-11.
--
-- Published check: Back Bay holds a single listing, 10813, whose price rises
-- $106 -> $150, so the neighborhood average is $44. This query returns $44.
--
-- Those two dates are parameters of *this question*, not properties of the
-- data. They are read from vars (price_comparison_start_date /
-- price_comparison_end_date, set in dbt_project.yml) rather than derived from
-- MIN and MAX of the calendar, because the two are different things that
-- happen to coincide in the current extract. Deriving them would mean that
-- loading one more day of calendar silently changes the answer to a question
-- that named its own dates -- and nobody would see it happen.
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
-- has_listing_record filters out listing 276450, which has prices but no
-- neighborhood. That is a deliberate exclusion for a neighborhood cut, not an
-- accidental one -- an inner join to the listing table would have done it
-- silently.

with comparison_dates as (

    select
        cast('{{ var("price_comparison_start_date") }}' as date) as start_date,
        cast('{{ var("price_comparison_end_date") }}'   as date) as end_date

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
