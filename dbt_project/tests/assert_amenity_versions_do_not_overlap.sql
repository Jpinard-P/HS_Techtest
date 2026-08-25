-- The as-of join in listing_days is only single-valued if each listing's
-- validity ranges are disjoint and contiguous. If two versions overlapped,
-- every day in the overlap would appear twice in the mart and be counted
-- twice; if they left a gap, days in the gap would lose their amenities and
-- drop out of amenity segmentation.

with versions as (

    select
        listing_id,
        version_number,
        valid_from,
        valid_to,
        lead(valid_from) over (partition by listing_id order by version_number) as next_valid_from
    from {{ ref('int_amenities_versioned') }}

)

select *
from versions
where
    -- a version must end after it starts
    valid_to <= valid_from
    -- and must hand over to the next one exactly, with no gap and no overlap
    or (next_valid_from is not null and next_valid_from <> valid_to)
