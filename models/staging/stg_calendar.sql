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
        "LISTING_ID"                                         as listing_id,
        -- DATE is documented as DATETIME but every value is midnight and the
        -- column is half of a daily grain, so it is narrowed to a real date.
        cast("DATE" as date)                                 as calendar_date,
        -- AVAILABLE is documented as VARCHAR holding 't' / 'f'.
        "AVAILABLE" = 't'                                    as is_available,
        -- The source spells "no reservation" as the literal text NULL; that
        -- sentinel is mapped to a real NULL at read time (see _staging__sources.yml)
        -- so this column already arrives as the documented INTEGER.
        "RESERVATION_ID"                                     as reservation_id,
        cast("PRICE" as decimal(10, 2))                      as calendar_price,
        "MINIMUM_NIGHTS"                                     as minimum_nights,
        "MAXIMUM_NIGHTS"                                     as maximum_nights

    from deduped

)

select * from renamed
