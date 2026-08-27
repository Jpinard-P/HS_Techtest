-- Golden-number regression guard for the three published business answers.
--
-- These are not invariants of the model -- they are facts about this extract,
-- independently re-derived here rather than read from analyses/. That is the
-- point: if a change to a join, a cast, or an amenity flag moves one of these
-- numbers, the build fails naming the number that moved, instead of the drift
-- being noticed at a code review months later.
--
-- If the source data is legitimately refreshed, these expected values are meant
-- to be updated deliberately, in the same commit that refreshes the data.

with amenity_revenue_july_2022 as (

    select
        'amenity_revenue_july_2022' as check_name,
        round(
            100.0 * sum(case when not has_air_conditioning then revenue else 0 end) / sum(revenue),
            1
        ) as actual_value,
        21.2 as expected_value
    from {{ ref('listing_days') }}
    where month_start_date = date '2022-07-01'

),

back_bay_price_increase as (

    select
        'back_bay_avg_price_increase' as check_name,
        round(avg(price_at_end - price_at_start), 2) as actual_value,
        44.00 as expected_value
    from (
        select
            listing_id,
            -- The question's own dates, pinned here as well as in
            -- analyses/02 -- a golden test should be self-contained, so it
            -- deliberately shares nothing with the query it guards.
            max(case when calendar_date = date '2021-07-12' then nightly_price end) as price_at_start,
            max(case when calendar_date = date '2022-07-11' then nightly_price end) as price_at_end
        from {{ ref('listing_days') }}
        where neighborhood = 'Back Bay'
        group by 1
    )

),

longest_stay_1303261 as (

    select
        'longest_stay_listing_1303261' as check_name,
        max(max_bookable_nights) as actual_value,
        159 as expected_value
    from {{ ref('listing_days') }}
    where listing_id = 1303261
      and has_lockbox
      and has_first_aid_kit

),

all_checks as (

    select * from amenity_revenue_july_2022
    union all select * from back_bay_price_increase
    union all select * from longest_stay_1303261

)

select *
from all_checks
where actual_value is distinct from expected_value
