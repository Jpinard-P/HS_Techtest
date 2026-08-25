-- Problem 1: total revenue and percentage of revenue by month, segmented by
-- whether the listing had air conditioning.
--
-- Published check: 21.2% of July 2022 revenue came from listings without air
-- conditioning. This query returns 21.2%.
--
-- Three things the mart is doing for this query:
--
--   * has_air_conditioning is resolved as of each day, not from the listing's
--     current amenity set. Today those agree, because every amenity change in
--     this extract predates the loaded calendar. The day a change lands inside
--     the loaded calendar, this query keeps working and a current-state join silently
--     starts misattributing pre-change revenue.
--
--   * revenue is already zero on unbooked nights, so no WHERE clause is needed
--     to avoid counting asking prices as takings.
--
--   * is_complete_month is surfaced rather than filtered. July 2021 and July
--     2022 are partial (20 and 11 days), and their totals are not comparable
--     to a full month -- but the published 21.2% figure is for partial July
--     2022, so excluding them here would answer a different question.

select
    strftime(month_start_date, '%Y-%m') as month,
    is_complete_month,
    case when has_air_conditioning then 'With AC' else 'Without AC' end as ac_segment,

    sum(revenue) as revenue,

    round(
        100.0 * sum(revenue) / sum(sum(revenue)) over (partition by month_start_date),
        1
    ) as pct_of_month_revenue

from {{ ref('listing_days') }}
group by
    month_start_date,
    is_complete_month,
    has_air_conditioning
order by
    month_start_date,
    ac_segment
