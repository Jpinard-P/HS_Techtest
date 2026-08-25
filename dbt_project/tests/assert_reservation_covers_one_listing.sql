-- RESERVATION_ID is documented as the "Unique ID for that DATE's reservation",
-- so one reservation belongs to one property and occupies a contiguous block
-- of nights. Reservation ids are in fact allocated in per-listing blocks
-- (listing 3781 holds 1-41, 5506 holds 42-89, and so on).
--
-- Known exception, which is why this test warns rather than errors:
-- reservation 836 appears on two different listings (753446 and 801680) on the
-- same date, 2021-07-12 -- the first day of the loaded calendar. It is the only
-- reservation on 753446. This looks like an off-by-one where the id blocks
-- meet at the loaded calendar boundary, but it cannot be resolved from the data alone,
-- so it is surfaced rather than silently repaired.
{{ config(severity = 'warn') }}

select
    reservation_id,
    count(distinct listing_id) as listing_count,
    count(*)                   as night_count
from {{ ref('stg_calendar') }}
where reservation_id is not null
group by 1
having count(distinct listing_id) > 1
