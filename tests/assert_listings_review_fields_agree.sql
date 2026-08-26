-- NUMBER_OF_REVIEWS, FIRST_REVIEW, and LAST_REVIEW are three independent
-- columns describing one fact, so they can drift apart. Two listings in the
-- current extract have zero reviews and NULL review dates, which is the
-- consistent case; this test catches the inconsistent ones.

select
    listing_id,
    number_of_reviews,
    first_review_date,
    last_review_date
from {{ ref('stg_listings') }}
where
    -- a review count with no dates to back it, or dates with no count
    (number_of_reviews > 0 and (first_review_date is null or last_review_date is null))
    or (number_of_reviews = 0 and (first_review_date is not null or last_review_date is not null))
    -- or a first review that postdates the last one
    or first_review_date > last_review_date
