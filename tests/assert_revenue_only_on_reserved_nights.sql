-- revenue and nightly_price are separate columns precisely so that summing
-- revenue is always correct. That guarantee is only worth anything if revenue
-- is exactly nightly_price on reserved nights and exactly zero otherwise.

select
    listing_id,
    calendar_date,
    is_reserved,
    nightly_price,
    revenue
from {{ ref('listing_days') }}
where
    (is_reserved and revenue <> nightly_price)
    or (not is_reserved and revenue <> 0)
    -- is_available and is_reserved are both exposed; they must stay inverses
    or is_available = is_reserved
