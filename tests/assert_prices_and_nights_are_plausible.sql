-- Range checks on the numeric columns that feed revenue and availability
-- measures. A zero or negative price, or a maximum stay shorter than the
-- minimum, is not a value the business can act on -- it is a parsing or
-- source error, and it should stop the build rather than land in a metric.

select 'stg_listings' as model, listing_id, 'listing_price' as column_name, listing_price::varchar as value
from {{ ref('stg_listings') }}
where listing_price <= 0

union all
select 'stg_listings', listing_id, 'review_scores_rating', review_scores_rating::varchar
from {{ ref('stg_listings') }}
where review_scores_rating not between 0 and 5

union all
select 'stg_listings', listing_id, 'accommodates', accommodates::varchar
from {{ ref('stg_listings') }}
where accommodates < 1

union all
select 'stg_calendar', listing_id, 'calendar_price', calendar_price::varchar
from {{ ref('stg_calendar') }}
where calendar_price <= 0

union all
select 'stg_calendar', listing_id, 'minimum_nights', minimum_nights::varchar
from {{ ref('stg_calendar') }}
where minimum_nights < 1 or minimum_nights > maximum_nights
