-- Within a listing, the nights of a single reservation form an unbroken run.
-- A gap would mean either a reused reservation id or a missing calendar day,
-- both of which would distort length-of-stay and occupancy measures.

select
    listing_id,
    reservation_id,
    count(*) as night_count,
    datediff('day', min(calendar_date), max(calendar_date)) + 1 as span_days
from {{ ref('stg_calendar') }}
where reservation_id is not null
group by 1, 2
having count(*) <> datediff('day', min(calendar_date), max(calendar_date)) + 1
