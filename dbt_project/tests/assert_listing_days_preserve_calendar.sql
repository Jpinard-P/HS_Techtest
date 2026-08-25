-- The mart must neither gain nor lose listing-days relative to the calendar it
-- is built from. A row count match alone would not catch a fan-out that also
-- dropped rows, so this compares both directions and the revenue total.
--
-- The revenue leg is the one that matters commercially: it asserts that the
-- mart's earned revenue still equals the sum of prices on reserved nights in
-- staging, so no join has quietly added or removed money.

with calendar as (

    select
        count(*)                                                     as day_count,
        sum(case when is_available then 0 else calendar_price end)   as revenue
    from {{ ref('stg_calendar') }}

),

mart as (

    select
        count(*)     as day_count,
        sum(revenue) as revenue
    from {{ ref('listing_days') }}

)

select
    calendar.day_count as calendar_day_count,
    mart.day_count     as mart_day_count,
    calendar.revenue   as calendar_revenue,
    mart.revenue       as mart_revenue
from calendar
cross join mart
where calendar.day_count <> mart.day_count
   or calendar.revenue <> mart.revenue
