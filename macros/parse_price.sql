-- PRICE columns arrive as text with an optional leading currency symbol --
-- "$280.00" in LISTINGS, a bare "125" in CALENDAR. These two macros split
-- that text into the two facts it carries, how much and in what currency, so
-- every price in staging is parsed one way.
--
-- \p{Sc} is the Unicode currency-symbol class, so a euro or pound sign
-- arriving in a future extract is captured as a symbol rather than left in
-- the string to break the amount cast. The symbol resolves to an ISO code
-- against the currency_symbols seed in the staging model; a symbol the seed
-- does not map resolves to NULL, which a not_null test turns into a build
-- failure that names the rows. The fix is one row in
-- seeds/currency_symbols.csv.
--
-- The amount cast stays strict (cast, not try_cast): once the one optional
-- leading symbol and thousands separators are gone, anything that still is
-- not a number should fail the build loudly rather than become a NULL in a
-- money column. A trailing symbol ("12,50 €") fails that cast today by
-- design; support it here, deliberately, if such an extract ever arrives.

{% macro price_currency_symbol(column) %}
    nullif(regexp_extract(trim({{ column }}), '^(\p{Sc})', 1), '')
{% endmacro %}

{% macro price_amount(column) %}
    cast(
        replace(regexp_replace(trim({{ column }}), '^\p{Sc}', ''), ',', '')
        as decimal(10, 2)
    )
{% endmacro %}
