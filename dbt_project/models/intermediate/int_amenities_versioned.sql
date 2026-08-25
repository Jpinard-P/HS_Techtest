-- Amenities are a slowly-changing attribute, delivered as a changelog rather
-- than as a current-state table. This model turns that changelog into
-- type-2 versions with explicit validity ranges, so any listing-day can be
-- joined to the amenity set that was actually in force on that day.
--
-- Why this matters even though it looks like overkill on the current extract:
-- every one of the 100 changes predates the loaded calendar (the last is
-- 2021-07-06, the calendar opens 2021-07-12), so today an as-of-day join and a
-- "join the latest row" shortcut return identical numbers. The moment one
-- change lands inside the loaded calendar the shortcut starts attributing pre-change
-- revenue to post-change amenities, and it does so silently. Modelling the
-- validity range now means that day is a data change, not a rebuild.

with changelog as (

    select * from {{ ref('stg_amenities_changelog') }}

),

versioned as (

    select
        listing_id,
        amenities,
        change_at,
        row_number() over (partition by listing_id order by change_at) as version_number,
        lead(change_at)      over (partition by listing_id order by change_at) as next_change_at,
        count(*)             over (partition by listing_id) as total_versions
    from changelog

),

final as (

    select
        listing_id,
        version_number,
        amenities,
        len(amenities) as amenity_count,

        -- The first version's validity is extended backwards to the beginning
        -- of time. The changelog records when a list *changed*, not when the
        -- listing began, so there is no record of what came before the first
        -- entry. Extending it guarantees every listing-day resolves to exactly
        -- one version; the alternative leaves NULL amenities on early days,
        -- which would silently drop those days out of any amenity segmentation
        -- rather than announcing itself.
        case
            when version_number = 1 then cast('-infinity' as timestamp)
            else change_at
        end as valid_from,

        -- Half-open interval [valid_from, valid_to): the row that supersedes
        -- this one starts exactly where it ends, so an as-of join can never
        -- match two versions for the same instant.
        coalesce(next_change_at, cast('infinity' as timestamp)) as valid_to,

        change_at as changed_at,
        version_number = total_versions as is_current_version

    from versioned

)

select * from final
