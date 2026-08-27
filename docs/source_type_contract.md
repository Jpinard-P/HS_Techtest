# Source type contract

The source documentation (*Table Descriptions*, revised January 2026) is the
single source of truth for the raw layer. `models/staging/_staging__sources.yml`
pins an explicit `types = [...]` list on every `read_csv` call so each raw
table materialises with exactly the documented types, instead of whatever
DuckDB's CSV sniffer infers from the current extract.

Without those pins the sniffer disagrees with the documentation on four
columns, purely because the current 51-listing extract happens to be clean:

| Table | Column | Documented | Sniffed from extract |
| --- | --- | --- | --- |
| LISTINGS | `BEDROOMS` | VARCHAR | BIGINT |
| LISTINGS | `REVIEW_SCORES_RATING` | VARCHAR | DOUBLE |
| LISTINGS | `FIRST_REVIEW` / `LAST_REVIEW` | VARCHAR | DATE |
| CALENDAR | `AVAILABLE` | VARCHAR | BOOLEAN |
| CALENDAR | `PRICE` | VARCHAR | BIGINT |

Pinning matters because the sniffed type is not stable: the first `BEDROOMS`
value of `"Studio"`, or the first `PRICE` written as `"249.50"`, silently
changes a column's type and breaks every model downstream of it. With the
types pinned, the raw layer's shape is fixed by the contract and only the
staging casts have to move.

## Deviations

Everything in the documentation is reproduced literally except the two items
below.

### 1. `DATETIME` is stored as `TIMESTAMP`

`HOST_SINCE`, `CALENDAR.DATE`, and `CHANGE_AT` are documented as `DATETIME`.
DuckDB accepts `DATETIME` in the `types` list — it is an alias — but reports
the column as `TIMESTAMP`. Same type, same precision, different spelling.
Nothing is lost; `dbt docs` shows the documented `DATETIME` because the
`data_type` in the YAML is set from the documentation.

### 2. `CALENDAR.RESERVATION_ID` needs a null sentinel to be an INTEGER

The column is documented as `INTEGER`, with "If NULL, there was no
reservation on that date". The file does not leave that field empty — it
writes the four-character string `NULL`, in 8,193 of 18,252 rows. An
`INTEGER` read of the file as-is therefore fails.

The read passes `nullstr = ['NULL', '']` so the sentinel becomes a real NULL
and the documented `INTEGER` type applies at read time. This is a lossless
reinterpretation of the sentinel the documentation already describes, but it
is a behaviour the documentation does not mention, so it is called out here
and in a comment on the source itself.

## Where the data contradicts the documentation

These are data-quality facts rather than typing problems. Each breaks a
guarantee the documentation makes; the full ledger — every issue, its
disposition, and the evidence behind each call — is in
[`data_story.md`](data_story.md), §3–§5. In brief:

- **`LISTINGS.ID` is documented as the Primary Key, but two rows have no ID.**
  One is a synthetic test record (`TESTING LISTING`, `HOST_ID = -99999`) and
  is dropped in `stg_listings`. The other is a real listing whose ID is
  recovered as `276450` — in `stg_listings`, not in the CSV, so the extract
  stays byte-identical — on four independent facts that
  `assert_recovered_listing_matches_its_evidence` re-checks on every build.
  Because every referenced listing therefore resolves, the two
  `relationships` tests error rather than warn. (When re-deriving the
  amenity evidence, compare the sets, not the raw strings: the two files
  format the same JSON array differently, so a string comparison reports no
  matches anywhere.)
- **`CALENDAR`'s documented `(LISTING_ID, DATE)` primary key is not unique.**
  Listing `1303261` on `2022-07-07` appears three times, identical in every
  column, so `stg_calendar` collapses the rows with `DISTINCT` and a
  singular test guards the grain from here on.
- **One reservation id spans two listings.** Reservation `836` appears on
  both `753446` and `801680` on `2021-07-12`. Nothing in the data says which
  listing it belongs to, so nothing is repaired:
  `assert_reservation_covers_one_listing` warns on it, and CI pins the
  warning.

## Staging deviates from the raw types on purpose

The raw layer matches the documentation; the staging layer does not, and
should not. `stg_*` casts the documented-VARCHAR columns that hold numbers,
dates, and booleans into usable types — `BEDROOMS` to `INTEGER`, `PRICE` to
`DECIMAL(10,2)` (splitting off the currency marking — see the `parse_price`
macros and the `currency_symbols` seed), the review dates to `DATE`,
`REVIEW_SCORES_RATING` to `DECIMAL(3,2)`, and `AVAILABLE`'s `'t'`/`'f'` to a
real `BOOLEAN`. `CALENDAR.DATE` is narrowed from `DATETIME` to `DATE`; every
value is midnight and the column is half of a daily grain.

Those casts are strict (`cast`, not `try_cast`) by design. A value the source
contract permits but staging cannot interpret should fail the build loudly
rather than quietly become NULL in a metric.
