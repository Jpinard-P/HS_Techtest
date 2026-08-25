-- max_bookable_nights is the column that answers "longest possible stay", so
-- it must never exceed either constraint it is built from: the length of the
-- vacancy, or the owner's stated maximum.

select
    listing_id,
    calendar_date,
    available_run_nights,
    maximum_nights,
    max_bookable_nights
from {{ ref('listing_days') }}
where max_bookable_nights is not null
  and (
        max_bookable_nights > available_run_nights
     or max_bookable_nights > maximum_nights
     or max_bookable_nights < 1
  )
