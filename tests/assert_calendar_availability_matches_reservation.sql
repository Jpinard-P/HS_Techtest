-- The documentation defines AVAILABLE and RESERVATION_ID independently:
-- AVAILABLE is 't'/'f', and RESERVATION_ID "if NULL, there was no reservation
-- on that date". Nothing guarantees the two agree, but in the current extract
-- they agree on all 18,250 rows. Downstream occupancy logic can therefore use
-- either one -- this test is what makes that safe.

select
    listing_id,
    calendar_date,
    is_available,
    reservation_id
from {{ ref('stg_calendar') }}
where is_available = (reservation_id is not null)
