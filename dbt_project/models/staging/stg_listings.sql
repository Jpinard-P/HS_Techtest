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
        "ID"                                                 as listing_id,
        "NAME"                                               as listing_name,
        "HOST_ID"                                            as host_id,
        "HOST_NAME"                                          as host_name,
        "HOST_SINCE"                                         as host_since,
        "HOST_LOCATION"                                      as host_location,
        -- HOST_VERIFICATIONS / AMENITIES are documented as VARCHAR parseable
        -- as JSON; casting to VARCHAR[] here just makes them queryable list
        -- types, it does not interpret their contents.
        cast("HOST_VERIFICATIONS" as json)::varchar[]        as host_verifications,
        "NEIGHBORHOOD"                                       as neighborhood,
        "PROPERTY_TYPE"                                      as property_type,
        "ROOM_TYPE"                                          as room_type,
        "ACCOMMODATES"                                       as accommodates,
        "BATHROOMS_TEXT"                                     as bathrooms_text,
        -- The remaining casts turn documented-VARCHAR columns that hold
        -- numbers and dates into usable types. They are deliberately strict
        -- (cast, not try_cast): a value the source contract allows but this
        -- model can't interpret should fail the build loudly rather than
        -- silently become NULL.
        cast("BEDROOMS" as integer)                          as bedrooms,
        "BEDS"                                               as beds,
        cast("AMENITIES" as json)::varchar[]                 as amenities,
        -- PRICE carries a currency symbol, e.g. "$125.00".
        cast(replace("PRICE", '$', '') as decimal(10, 2))    as listing_price,
        "NUMBER_OF_REVIEWS"                                  as number_of_reviews,
        cast("FIRST_REVIEW" as date)                         as first_review_date,
        cast("LAST_REVIEW" as date)                          as last_review_date,
        cast("REVIEW_SCORES_RATING" as decimal(3, 2))        as review_scores_rating

    from source

)

select * from renamed
