{{ config(materialized='view') }}

-- Two raw rows arrive with a NULL id. They are not the same kind of problem,
-- and they are not treated the same way.
--
-- The first is "TESTING LISTING": host_id -99999, accommodates 99, price
-- $999.99. It is synthetic and corresponds to nothing in CALENDAR. It stays
-- dropped.
--
-- The second is a real listing whose id was lost in the extract, and it is
-- recoverable rather than guessable. CALENDAR and AMENITIES_CHANGELOG each
-- describe 50 listings; LISTINGS identifies 49; exactly one id (276450) is
-- referenced by both and identified by neither. Three independent facts point
-- the remaining row at that id:
--
--   * its PRICE, $280.00, is unique across all 51 raw rows, and equals 276450's
--     CALENDAR price on 2021-07-12 -- which is what PRICE is documented to
--     mean, "the price of this listing as of the start of the date range in
--     CALENDAR".
--   * its AMENITIES set is exactly equal (28 of 28) to 276450's changelog
--     version of 2021-02-01. Only two of the 100 changelog rows match it
--     exactly, and the other belongs to listing 349347, which is already
--     identified.
--   * host 814298 also owns 349347, "...South End 1BR 1BA #2", in the same
--     neighborhood. This row is "#3" -- the sibling unit.
--
-- The id is therefore restored here rather than in data/LISTINGS.csv, so the
-- vendor extract stays byte-identical and the inference stays reviewable. The
-- evidence above is re-checked on every build by
-- assert_recovered_listing_matches_its_evidence; if a future extract changes
-- this row, that test fails rather than this model mislabelling it.
with source as (

    select
        case
            when "ID" is null
             and "HOST_ID" = 814298
             and "NAME" = '19th Century Luxury | South End | 1BR 1BA #3'
            then 276450
            else "ID"
        end as "ID",
        * exclude ("ID")
    from {{ source('raw', 'listings') }}

),

identified as (

    -- Anything still without an id cannot be joined to CALENDAR or
    -- AMENITIES_CHANGELOG and is unusable downstream. Today that is exactly
    -- the TESTING LISTING row.
    select * from source where "ID" is not null

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
        -- PRICE arrives as text with a leading currency symbol ("$280.00").
        -- parse_price splits it into the amount (strict cast) and the
        -- symbol, which resolves to an ISO code in the final CTE below.
        {{ price_amount('"PRICE"') }}                        as listing_price,
        {{ price_currency_symbol('"PRICE"') }}               as listing_price_currency_symbol,
        "NUMBER_OF_REVIEWS"                                  as number_of_reviews,
        cast("FIRST_REVIEW" as date)                         as first_review_date,
        cast("LAST_REVIEW" as date)                          as last_review_date,
        cast("REVIEW_SCORES_RATING" as decimal(3, 2))        as review_scores_rating

    from identified

),

currencies as (

    select currency_symbol, currency_code from {{ ref('currency_symbols') }}

),

final as (

    select
        renamed.* exclude (listing_price_currency_symbol),

        -- The documentation says prices are USD, so an unmarked price keeps
        -- that default. A marked price resolves through the seed, and a
        -- symbol the seed does not map resolves to NULL -- which the
        -- not_null test on this column turns into a build failure naming the
        -- rows, instead of a euro price quietly joining the dollar totals.
        case
            when renamed.listing_price_currency_symbol is null then 'USD'
            else currencies.currency_code
        end as listing_price_currency

    from renamed
    left join currencies
        on currencies.currency_symbol = renamed.listing_price_currency_symbol

)

select * from final
