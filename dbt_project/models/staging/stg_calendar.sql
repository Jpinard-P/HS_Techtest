{{ config(materialized='view') }}

with source as (

    select *
    from {{ source('raw', 'calendar') }}

),

-- Three fully-identical rows exist for (listing_id=1303261, date=2022-07-07).
-- Since every column matches, this is a straight duplicate rather than
-- conflicting data, so distinct-ing them back to one row loses no
-- information and restores the documented (listing_id, date) primary key.
deduped as (

    select distinct *
    from source

),

renamed as (

    select
        "LISTING_ID"                                          as listing_id,
        "DATE"                                                as calendar_date,
        "AVAILABLE"                                           as is_available,
        -- RESERVATION_ID is read as VARCHAR because the source encodes
        -- "no reservation" as the literal text "NULL" rather than an empty
        -- field, which blocks DuckDB's numeric type inference. NULLIF
        -- converts that sentinel to a real NULL before casting.
        cast(nullif("RESERVATION_ID", 'NULL') as bigint)      as reservation_id,
        "PRICE"                                               as calendar_price,
        "MINIMUM_NIGHTS"                                      as minimum_nights,
        "MAXIMUM_NIGHTS"                                      as maximum_nights

    from deduped

)

select * from renamed
