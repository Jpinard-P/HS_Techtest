-- One row per stay: the reservation-grain mart. Length-of-stay, revenue per
-- booking, and nightly-rate-by-stay-length questions all need the booking as
-- the unit, and deriving stays repeatedly in the reporting layer is how two
-- dashboards end up with two different average-length-of-stay numbers.
--
-- Built from listing_days, not from staging, and that choice is the point:
-- listing_days is incremental precisely so days that age out of the source's
-- rolling window are retained, and a stay mart aggregated from it inherits
-- that retention for free. Aggregating from stg_calendar instead would
-- silently lose every stay the source has already forgotten, and its revenue
-- could drift from the mart's. One source of truth for money: this table's
-- reservation_revenue is a straight SUM of listing_days.revenue, which
-- assert_reservations_preserve_reserved_days pins.
--
-- Grain is (listing_id, reservation_id), not reservation_id alone:
-- reservation 836 appears against two listings in this extract (see
-- docs/source_type_contract.md), so reservation_id is not globally unique.
--
-- The calendar-edge flags compare each stay against the mart's own coverage:
-- a stay touching either edge is only partly visible, so its nights and
-- revenue are lower bounds. Exclude truncated stays from any length-of-stay
-- average -- is_truncated_by_calendar makes that one WHERE clause.

with reserved_days as (

    select * from {{ ref('listing_days') }}
    where is_reserved

),

mart_coverage as (

    select
        min(calendar_date) as first_covered_date,
        max(calendar_date) as last_covered_date
    from {{ ref('listing_days') }}

),

final as (

    select
        reserved_days.listing_id,
        reserved_days.reservation_id,

        -- Listing attributes, denormalised exactly as listing_days carries
        -- them (any_value is safe: they are constant within a listing).
        any_value(reserved_days.has_listing_record) as has_listing_record,
        any_value(reserved_days.listing_name)       as listing_name,
        any_value(reserved_days.host_id)            as host_id,
        any_value(reserved_days.neighborhood)       as neighborhood,
        any_value(reserved_days.property_type)      as property_type,
        any_value(reserved_days.room_type)          as room_type,
        any_value(reserved_days.accommodates)       as accommodates,

        min(reserved_days.calendar_date)            as first_night,
        max(reserved_days.calendar_date)            as last_night,
        count(*)                                    as reservation_nights,
        sum(cast(reserved_days.is_weekend as int))  as weekend_nights,

        sum(reserved_days.revenue)                  as reservation_revenue,
        round(avg(reserved_days.nightly_price), 2)  as average_nightly_price,
        -- Single-valued per stay while assert_prices_share_one_currency
        -- holds mart-wide; if that test ever starts failing, this column is
        -- the one to group stays by.
        any_value(reserved_days.price_currency)     as price_currency,

        min(reserved_days.calendar_date) = any_value(mart_coverage.first_covered_date)
            as starts_at_calendar_start,
        max(reserved_days.calendar_date) = any_value(mart_coverage.last_covered_date)
            as ends_at_calendar_end,
        min(reserved_days.calendar_date) = any_value(mart_coverage.first_covered_date)
            or max(reserved_days.calendar_date) = any_value(mart_coverage.last_covered_date)
            as is_truncated_by_calendar

    from reserved_days
    cross join mart_coverage
    group by 1, 2

)

select * from final
