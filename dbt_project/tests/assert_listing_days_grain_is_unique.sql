-- The mart's grain is one row per listing per day. Every join in
-- listing_days is a potential fan-out -- the amenity as-of join especially,
-- since an overlapping validity range would silently duplicate a day and
-- double its revenue.

select
    listing_id,
    calendar_date,
    count(*) as row_count
from {{ ref('listing_days') }}
group by 1, 2
having count(*) > 1
