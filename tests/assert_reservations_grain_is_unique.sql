-- The stay mart's grain is one row per (listing_id, reservation_id). The
-- GROUP BY that builds it makes duplicates structurally unlikely, but the
-- grain is the published contract, and reservation 836 -- one id on two
-- listings -- is exactly the shape that would break a naive reservation_id
-- grain. This pins the composite one.

select
    listing_id,
    reservation_id,
    count(*) as row_count
from {{ ref('reservations') }}
group by 1, 2
having count(*) > 1
