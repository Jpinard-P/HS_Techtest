-- SUM(revenue) over any slice of the mart is only meaningful while every
-- price shares one currency. The staging layer is deliberately built to
-- admit others -- parse_price captures any currency symbol, and the
-- currency_symbols seed resolves it -- so the day a euro-denominated listing
-- lands, this fails the build and forces the choice (filter, convert, or
-- segment) instead of letting a monthly total quietly become dollars plus
-- euros. Problem 2's price deltas break the same way, for the same reason.

with currencies as (

    select
        price_currency,
        count(*) as day_count
    from {{ ref('listing_days') }}
    group by 1

)

select *
from currencies
where (select count(*) from currencies) > 1
