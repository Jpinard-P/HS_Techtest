-- Collapses the daily calendar to one row per reservation. The calendar
-- records occupancy a day at a time; questions about *stays* -- how long they
-- run, what they earned, how far ahead of the loaded calendar they started -- need the
-- booking as the unit, and deriving that repeatedly in the reporting layer is
-- how two dashboards end up with two different average-length-of-stay numbers.
--
-- Keyed on (listing_id, reservation_id) rather than reservation_id alone:
-- reservation 836 appears against two different listings, so reservation_id is
-- not globally unique in this extract. See docs/source_type_contract.md.

with reserved_days as (

    select *
    from {{ ref('stg_calendar') }}
    where reservation_id is not null

),

final as (

    select
        listing_id,
        reservation_id,
        min(calendar_date)                  as first_night,
        max(calendar_date)                  as last_night,
        count(*)                            as reservation_nights,
        sum(calendar_price)                 as reservation_revenue,
        round(avg(calendar_price), 2)       as average_nightly_price,

        -- A stay that began before the loaded calendar starts, or continues
        -- past where it ends, is only partly visible here: its nights and
        -- revenue are understated. These flags let a length-of-stay analysis
        -- exclude the truncated stays instead of quietly averaging them in.
        -- The bounds come from the data, so they stay correct as more
        -- calendar is loaded.
        min(calendar_date) = (select min(calendar_date) from {{ ref('stg_calendar') }}) as starts_at_calendar_start,
        max(calendar_date) = (select max(calendar_date) from {{ ref('stg_calendar') }}) as ends_at_calendar_end

    from reserved_days
    group by 1, 2

)

select * from final
