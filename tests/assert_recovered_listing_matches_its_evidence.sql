-- stg_listings restores a lost id: the raw row named "19th Century Luxury |
-- South End | 1BR 1BA #3" is assigned listing_id 276450. That is an inference,
-- not a value read from the file, so it is pinned here rather than trusted.
--
-- Each check below is one of the facts the inference rests on. If a future
-- extract changes the row -- a different price, a different amenity set, or the
-- id restored upstream and given to something else -- this fails and names
-- which fact stopped holding, instead of the model quietly attaching 365
-- calendar days and $76,520 of revenue to the wrong listing.

with recovered as (

    select * from {{ ref('stg_listings') }} where listing_id = 276450

),

calendar_first_day as (

    select calendar_price
    from {{ ref('stg_calendar') }}
    where listing_id = 276450
      and calendar_date = (select min(calendar_date) from {{ ref('stg_calendar') }})

),

checks as (

    select 'recovered listing 276450 is not present exactly once' as failed_check
    where (select count(*) from recovered) <> 1

    union all
    -- PRICE is documented as the price "as of the start of the date range in
    -- CALENDAR", so these two must be the same number.
    select 'recovered listing_price does not match its calendar price on day 1'
    where (select listing_price from recovered)
          is distinct from (select calendar_price from calendar_first_day)

    union all
    -- The amenity set must still equal one of 276450's own changelog versions.
    select 'recovered amenities match no changelog version for 276450'
    where not exists (
        select 1
        from {{ ref('stg_amenities_changelog') }} as v
        where v.listing_id = 276450
          and list_sort(v.amenities) = list_sort((select amenities from recovered))
    )

    union all
    -- The other null-id row is synthetic and must stay dropped. If the
    -- recovery rule ever widens to catch it, this fails.
    select 'the synthetic TESTING LISTING row is no longer excluded'
    where exists (select 1 from {{ ref('stg_listings') }} where host_id = -99999)

)

select * from checks
