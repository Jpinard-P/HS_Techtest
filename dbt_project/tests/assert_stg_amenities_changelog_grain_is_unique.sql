-- stg_amenities_changelog's documented grain is one row per
-- (listing_id, change_at). This returns any rows that violate that.

select
    listing_id,
    change_at,
    count(*) as row_count
from {{ ref('stg_amenities_changelog') }}
group by 1, 2
having count(*) > 1
