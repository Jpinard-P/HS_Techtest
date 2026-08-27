-- The stay mart must account for exactly the reserved nights and revenue
-- that listing_days holds: as many nights as there are reserved rows, and
-- to-the-cent the same money. A drift in either direction means the
-- re-aggregation added or lost stays -- and because this mart is the one
-- length-of-stay numbers come from, that drift would surface as a business
-- trend rather than an error.

with mart as (

    select
        sum(reservation_nights)  as nights,
        sum(reservation_revenue) as revenue,
        count(*)                 as stay_count
    from {{ ref('reservations') }}

),

source_days as (

    select
        count(*)                                  as nights,
        sum(revenue)                              as revenue,
        count(distinct (listing_id, reservation_id)) as stay_count
    from {{ ref('listing_days') }}
    where is_reserved

)

select
    mart.nights     as mart_nights,
    source_days.nights  as source_nights,
    mart.revenue    as mart_revenue,
    source_days.revenue as source_revenue,
    mart.stay_count as mart_stays,
    source_days.stay_count as source_stays
from mart
cross join source_days
where mart.nights     <> source_days.nights
   or mart.revenue    <> source_days.revenue
   or mart.stay_count <> source_days.stay_count
