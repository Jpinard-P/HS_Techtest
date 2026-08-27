-- One row per host: the customer dimension. For a property management
-- company the host is who the business answers to, and until this table the
-- host existed only as an id column on listings. Portfolio size, spread, and
-- performance questions -- who operates multiple units, which hosts
-- underperform their neighborhood, does tenure correlate with occupancy --
-- all group by host, and each analyst doing that grouping ad hoc repeats
-- the same aggregation with the same subtle choices.
--
-- Built from the listings mart, so per-listing occupancy and revenue are
-- aggregated exactly once, there, and only rolled up here.
--
-- any_value on the host attributes is safe because the source repeats them
-- identically on every listing a host owns; assert_host_attributes_agree
-- pins that, so a future extract where one host row disagrees fails the
-- build instead of letting any_value pick an arbitrary version.

with listings as (

    select * from {{ ref('listings') }}

),

final as (

    select
        host_id,
        any_value(host_name)     as host_name,
        any_value(host_since)    as host_since,
        any_value(host_location) as host_location,

        count(*)                                       as listings_count,
        count(distinct neighborhood)                   as neighborhoods_count,
        list_sort(list(distinct neighborhood))         as neighborhoods,

        sum(nights_in_calendar)                        as nights_in_calendar,
        sum(nights_reserved)                           as nights_reserved,
        -- Portfolio occupancy: reserved nights over available-to-book
        -- nights, weighted by listing coverage rather than averaged per
        -- listing, so a host's one busy unit cannot be diluted by how the
        -- rows are counted.
        round(sum(nights_reserved) * 1.0 / sum(nights_in_calendar), 3)
                                                       as occupancy_rate,
        sum(revenue_in_calendar)                       as revenue_in_calendar,

        sum(number_of_reviews)                         as total_reviews,
        round(avg(review_scores_rating), 2)            as average_review_score,
        min(first_review_date)                         as first_review_date,
        max(last_review_date)                          as last_review_date

    from listings
    group by 1

)

select * from final
