-- The read_csv calls in _staging__sources.yml pin each column's type positionally
-- (types = [...]). DuckDB's name-keyed alternative, columns = {...}, is not
-- safer: it also assigns by position, and a name that doesn't match the file
-- silently RENAMES the column instead of raising. Positional typing is
-- therefore only correct while the files keep the column order the source
-- documentation gives.
--
-- This test asserts that order. Without it, a reordered extract whose swapped
-- columns happen to share a type (MINIMUM_NIGHTS / MAXIMUM_NIGHTS, say) would
-- be mis-typed silently rather than failing the build.

with documented as (

    select 'LISTINGS' as source_file, [
        'ID', 'NAME', 'HOST_ID', 'HOST_NAME', 'HOST_SINCE', 'HOST_LOCATION',
        'HOST_VERIFICATIONS', 'NEIGHBORHOOD', 'PROPERTY_TYPE', 'ROOM_TYPE',
        'ACCOMMODATES', 'BATHROOMS_TEXT', 'BEDROOMS', 'BEDS', 'AMENITIES',
        'PRICE', 'NUMBER_OF_REVIEWS', 'FIRST_REVIEW', 'LAST_REVIEW',
        'REVIEW_SCORES_RATING'
    ] as columns

    union all
    select 'CALENDAR', [
        'LISTING_ID', 'DATE', 'AVAILABLE', 'RESERVATION_ID', 'PRICE',
        'MINIMUM_NIGHTS', 'MAXIMUM_NIGHTS'
    ]

    union all
    select 'AMENITIES_CHANGELOG', [
        'LISTING_ID', 'CHANGE_AT', 'AMENITIES'
    ]

),

actual as (

    select 'LISTINGS' as source_file,
           list_transform(Columns, c -> c.name) as columns
    from sniff_csv('../data/LISTINGS.csv')

    union all
    select 'CALENDAR', list_transform(Columns, c -> c.name)
    from sniff_csv('../data/CALENDAR.csv')

    union all
    select 'AMENITIES_CHANGELOG', list_transform(Columns, c -> c.name)
    from sniff_csv('../data/AMENITIES_CHANGELOG.csv')

)

select
    documented.source_file,
    documented.columns as documented_columns,
    actual.columns     as actual_columns
from documented
join actual using (source_file)
where documented.columns != actual.columns
