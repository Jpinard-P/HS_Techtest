-- stg_calendar's documented grain is one row per (listing_id, calendar_date).
-- This returns any rows that violate that, so the test fails if new
-- duplicates show up (the one known case is already deduped in staging).

select
    listing_id,
    calendar_date,
    count(*) as row_count
from {{ ref('stg_calendar') }}
group by 1, 2
having count(*) > 1
