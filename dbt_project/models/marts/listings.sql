-- One row per listing, carrying the descriptive attributes that don't change
-- day to day, plus the listing's current amenity set.
--
-- listing_days already denormalises the attributes an analyst needs while
-- slicing daily revenue, so this dimension is not required to answer the
-- reporting questions. It exists for the listing-level questions -- how many
-- listings per neighbourhood, what share of the portfolio has a lockbox --
-- where scanning 18,250 daily rows to count 50 listings invites both slow
-- queries and accidental double counting.

with listings as (

    select * from {{ ref('stg_listings') }}

),

current_amenities as (

    select
        listing_id,
        amenities,
        amenity_count,
        changed_at as amenities_last_changed_at,
        version_number as amenity_version_count
    from {{ ref('int_amenities_versioned') }}
    where is_current_version

),

calendar_activity as (

    select
        listing_id,
        count(*)                                          as nights_in_calendar,
        sum(case when not is_available then 1 else 0 end) as nights_reserved,
        sum(case when not is_available then calendar_price else 0 end) as revenue_in_calendar
    from {{ ref('stg_calendar') }}
    group by 1

),

final as (

    select
        listings.listing_id,
        listings.listing_name,

        listings.host_id,
        listings.host_name,
        listings.host_since,
        listings.host_location,
        listings.host_verifications,

        listings.neighborhood,
        listings.property_type,
        listings.room_type,
        listings.accommodates,
        listings.bathrooms_text,
        listings.bedrooms,
        listings.beds,

        -- The listing-level PRICE is the price at the start of the calendar
        -- calendar only. It is kept for reference but deliberately named to stop
        -- it being mistaken for a current or average price -- the daily price
        -- lives in listing_days.
        listings.listing_price as price_at_calendar_start,

        listings.number_of_reviews,
        listings.first_review_date,
        listings.last_review_date,
        listings.review_scores_rating,

        current_amenities.amenities,
        current_amenities.amenity_count,
        current_amenities.amenities_last_changed_at,
        current_amenities.amenity_version_count,

        -- Exact matches, not LIKE. This amenity vocabulary contains 'Hair
        -- dryer' and 'Conditioner', both of which a '%air%' or '%conditio%'
        -- pattern would happily count as air conditioning, and 'Lock on
        -- bedroom door' alongside 'Lockbox'.
        list_contains(current_amenities.amenities, 'Air conditioning') as has_air_conditioning,
        list_contains(current_amenities.amenities, 'Lockbox')          as has_lockbox,
        list_contains(current_amenities.amenities, 'First aid kit')    as has_first_aid_kit,

        calendar_activity.nights_in_calendar,
        calendar_activity.nights_reserved,
        calendar_activity.revenue_in_calendar

    from listings
    left join current_amenities using (listing_id)
    left join calendar_activity using (listing_id)

)

select * from final
