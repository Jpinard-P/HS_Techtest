{{ config(materialized='view') }}

-- Two raw rows have a NULL id (one "TESTING LISTING" with host_id=-99999 and
-- other clearly implausible values, one otherwise-normal-looking row). A NULL
-- primary key can't be joined to CALENDAR or AMENITIES_CHANGELOG, so these
-- rows are unusable downstream and are dropped here rather than passed on.
with source as (

    select *
    from {{ source('raw', 'listings') }}
    where "ID" is not null

),

renamed as (

    select
        "ID"                                                as listing_id,
        "NAME"                                               as listing_name,
        "HOST_ID"                                             as host_id,
        "HOST_NAME"                                           as host_name,
        "HOST_SINCE"                                          as host_since,
        "HOST_LOCATION"                                       as host_location,
        -- HOST_VERIFICATIONS / AMENITIES arrive as JSON-array strings;
        -- casting to VARCHAR[] here just makes them queryable list types,
        -- it does not interpret their contents.
        cast("HOST_VERIFICATIONS" as json)::varchar[]        as host_verifications,
        "NEIGHBORHOOD"                                        as neighborhood,
        "PROPERTY_TYPE"                                       as property_type,
        "ROOM_TYPE"                                           as room_type,
        "ACCOMMODATES"                                        as accommodates,
        "BATHROOMS_TEXT"                                      as bathrooms_text,
        "BEDROOMS"                                            as bedrooms,
        "BEDS"                                                as beds,
        cast("AMENITIES" as json)::varchar[]                  as amenities,
        -- PRICE is stored as e.g. "$125.00"; strip the currency symbol so it
        -- can be used numerically.
        cast(replace("PRICE", '$', '') as decimal(10, 2))     as listing_price,
        "NUMBER_OF_REVIEWS"                                   as number_of_reviews,
        "FIRST_REVIEW"                                        as first_review_date,
        "LAST_REVIEW"                                         as last_review_date,
        "REVIEW_SCORES_RATING"                                as review_scores_rating

    from source

)

select * from renamed
