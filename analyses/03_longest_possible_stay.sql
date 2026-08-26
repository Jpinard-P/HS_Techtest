-- Problem 3: the longest possible stay for listings offering both a lockbox
-- and a first aid kit, respecting both the vacancy and the owner's maximum.
--
-- Published check: listing 1303261 has both amenities and a longest possible
-- stay of 159 days. This query returns 159.
--
-- The gaps-and-islands work is already done in the mart:
-- max_bookable_nights is least(length of this vacancy, strictest
-- maximum_nights across it), so the answer is a MAX over the listing's days.
--
-- The amenity filter is an exact match, which matters more than it looks. The
-- vocabulary contains 'Lock on bedroom door' as well as 'Lockbox', so
-- amenities LIKE '%lock%' would over-count; the same trap catches air
-- conditioning, where 'Hair dryer' matches '%air%'.
--
-- available_run_touches_calendar_edge is reported because a vacancy that runs to
-- the edge of the loaded calendar may well continue beyond it -- those stays
-- are lower bounds, not measurements.

with qualifying_days as (

    select *
    from {{ ref('listing_days') }}
    where has_lockbox
      and has_first_aid_kit
      and max_bookable_nights is not null

),

longest_per_listing as (

    select
        listing_id,
        max(max_bookable_nights) as longest_possible_stay_nights
    from qualifying_days
    group by 1

)

select
    longest.listing_id,
    days.neighborhood,
    longest.longest_possible_stay_nights,
    days.available_run_start_date,
    days.available_run_end_date,
    days.available_run_nights,
    days.maximum_nights,
    days.available_run_touches_calendar_edge
from longest_per_listing as longest

-- pull back the run that achieved the maximum, for context
join qualifying_days as days
    on  days.listing_id = longest.listing_id
    and days.max_bookable_nights = longest.longest_possible_stay_nights
    and days.calendar_date = days.available_run_start_date

-- if two runs tie for a listing's maximum, report the earlier one rather
-- than duplicating the listing
qualify row_number() over (
    partition by longest.listing_id
    order by days.available_run_start_date
) = 1

order by longest.longest_possible_stay_nights desc
