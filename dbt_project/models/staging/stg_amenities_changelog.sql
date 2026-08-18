{{ config(materialized='view') }}

with source as (

    select *
    from {{ source('raw', 'amenities_changelog') }}

),

renamed as (

    select
        "LISTING_ID"                                          as listing_id,
        "CHANGE_AT"                                           as change_at,
        cast("AMENITIES" as json)::varchar[]                  as amenities

    from source

)

select * from renamed
