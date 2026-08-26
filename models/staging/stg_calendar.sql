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
        -- PRICE arrives as bare numeric text today, but is parsed exactly
        -- like the listing price: an optional leading currency symbol is
        -- split off and resolved to an ISO code in the final CTE below, so a
        -- future extract that starts marking currencies changes a column
        -- value here, not the parse.
        {{ price_amount('"PRICE"') }}                        as calendar_price,
        {{ price_currency_symbol('"PRICE"') }}               as calendar_price_currency_symbol,
        "MINIMUM_NIGHTS"                                     as minimum_nights,
        "MAXIMUM_NIGHTS"                                     as maximum_nights

    from deduped

),

currencies as (

    select currency_symbol, currency_code from {{ ref('currency_symbols') }}

),

final as (

    select
        renamed.* exclude (calendar_price_currency_symbol),

        -- Documented as "The USD price", so an unmarked price keeps that
        -- default; a marked one resolves through the seed, and an unmapped
        -- symbol becomes NULL for the not_null test to name. Same contract
        -- as stg_listings.listing_price_currency.
        case
            when renamed.calendar_price_currency_symbol is null then 'USD'
            else currencies.currency_code
        end as calendar_price_currency

    from renamed
    left join currencies
        on currencies.currency_symbol = renamed.calendar_price_currency_symbol

)

select * from final
