# Rental analytics — data model

A dbt project over three source files (`LISTINGS`, `CALENDAR`,
`AMENITIES_CHANGELOG`) that produces a day/listing mart for revenue,
occupancy, and point-in-time amenity analysis.

```
models/
├── staging/                    views · schema: main
│   ├── _staging__sources.yml
│   ├── stg_listings.sql/.yml
│   ├── stg_calendar.sql/.yml
│   └── stg_amenities_changelog.sql/.yml
├── intermediate/               views · schema: main_intermediate
│   ├── int_amenities_versioned.sql/.yml
│   ├── int_calendar_days_collapsed_to_reservations.sql/.yml
│   └── int_calendar_days_grouped_into_availability_runs.sql/.yml
└── marts/                      tables · schema: main
    ├── listing_days.sql/.yml           ← the day/listing mart
    └── listings.sql/.yml
```

`dbt build` → 58 nodes, 0 errors, 3 intentional warnings (below).

---

## The three business problems

Each is in `analyses/`, written against the mart, and each reproduces the
figure published in the brief:

| # | Question | Published check | Result |
| --- | --- | --- | --- |
| 1 | Revenue by month, split by air conditioning | July 2022: 21.2% without AC | **21.2%** |
| 2 | Average price increase per neighborhood | Back Bay: $44, one listing | **$44** |
| 3 | Longest possible stay, lockbox + first aid kit | Listing 1303261: 159 days | **159** |

Those three numbers drove the design. Where a modelling choice could have gone
either way, the one that reproduces them won — and in one case that choice was
not the obvious one.

---

## The decisions that matter

### 1. `listing_days` is built on the calendar, not the listing

Listing `276450` has 365 calendar days and 2 amenity changes but **no row in
`LISTINGS`** — its ID was nulled at source. The evidence that it is the
corrupted row is strong: `LISTINGS` holds 49 usable IDs while the other two
tables cover 50 listings, and the nulled row *"19th Century Luxury | South End
| 1BR 1BA #3"* is priced `$280.00`, exactly `276450`'s calendar price on the
calendar's first day.

An inner join from calendar to listings would have dropped it silently. That
single join choice moves the answer to problem 1:

| | July 2022 revenue without AC |
| --- | --- |
| Calendar left-joined (orphan kept) | **21.2%** ← matches the brief |
| Inner join to listings (orphan dropped) | 22.1% |

So the fact is built from the calendar spine outwards, `has_listing_record`
marks the orphan, and its descriptive columns are NULL. Excluding it becomes a
deliberate `WHERE` clause — which problem 2 uses, because a neighborhood cut
genuinely cannot place a listing with no neighborhood.

### 2. Amenities are type-2 versioned, even though nothing needs it yet

Every one of the 100 amenity changes predates the loaded calendar — the last
is 2021-07-06, the calendar opens 2021-07-12. Amenities are therefore *constant*
across the entire reporting period, and `LISTINGS.AMENITIES` equals the latest
changelog row for all 49 listings.

Which means a current-state join produces identical numbers today, at a
fraction of the complexity. It was still the wrong choice. The moment one
change lands inside the loaded calendar, that shortcut starts attributing pre-change
revenue to post-change amenities, and it does it silently — no error, no row
count change, just a number that drifts. `int_amenities_versioned` builds
half-open `[valid_from, valid_to)` ranges, and the mart resolves amenities
as of each specific day. That day becomes a data change rather than a rebuild.

The first version of each listing is backdated to `-infinity`, because a
changelog records changes rather than origins. The alternative leaves NULL
amenities on early days, which drops them out of any amenity segmentation
instead of announcing itself.

### 3. `revenue` and `nightly_price` are separate columns

`CALENDAR.PRICE` exists on every row, booked or not. Summing it gives
*potential* revenue and overstates takings by roughly the vacancy rate.

Rather than rely on every analyst remembering a `WHERE is_reserved` clause,
the mart carries both: `nightly_price` (what was asked, every night) and
`revenue` (what was earned — the price when booked, `0` when not). `SUM(revenue)`
is correct over any combination of days, listings, and months without a filter.
A test enforces the relationship between them.

### 4. Analysis periods live in analyses, not in the model

Problem 2 names two dates: 2021-07-12 and 2022-07-11. The loaded calendar
happens to span exactly those dates, which makes it tempting to treat them as
one thing. They are not.

`2021-07-12 → 2022-07-11` is **the parameter of one business question**. The
calendar's extent is **a property of the data**, and it changes whenever more
data lands. Conflating them produces a specific, silent failure: derive
problem 2's endpoints from `MIN`/`MAX` of the calendar, load one more day, and
the answer to a question that named its own dates quietly changes — with no
error and no row-count difference to notice.

So the two are kept apart:

| | Where it lives | How it behaves when more calendar loads |
| --- | --- | --- |
| Problem 2's comparison period | `vars` in `dbt_project.yml`, read by `analyses/02` | Unchanged — it is pinned |
| Calendar coverage | Derived from the data in every model | Extends automatically |

**No model hardcodes a date.** Every coverage flag — `is_complete_month`,
`days_of_month_in_calendar`, `starts_at_calendar_start`,
`available_run_touches_calendar_edge` — is computed against the calendar's own
extent at run time, so extending the calendar corrects them without a code
change. The columns are named for the calendar rather than for a "window"
precisely so that nobody reads them as a business period.

### 5. Partial months are flagged, not hidden

The loaded calendar does not start or end on month boundaries, so its first and
last months are stubs: currently 20 days of July 2021 and 11 of July 2022. The mart's stated purpose is
period-over-period analysis, and those two stubs are precisely what breaks it —
July 2022 will always look like a 65% collapse in revenue next to June.

Every row carries `is_complete_month` and `days_of_month_in_calendar`. Note that
the brief's own 21.2% figure is for *partial* July 2022, so analysis 1 surfaces
the flag rather than filtering on it — the guard belongs in the analyst's hands,
visibly, not applied silently upstream.

### 6. Amenity flags are exact matches, never `LIKE`

The 81-value amenity vocabulary contains `Hair dryer` and `Conditioner`
alongside `Air conditioning`, and `Lock on bedroom door` alongside `Lockbox`.
`LIKE '%air%'` matches *Hair dryer*. `LIKE '%lock%'` matches *Lock on bedroom
door*. Both problems 1 and 3 would return quietly wrong answers.

The mart uses `list_contains(amenities, 'Air conditioning')`. The full
`amenities` array stays on every row so any amenity can be tested the same way,
without waiting for a new flag column.

### 7. Gaps-and-islands is solved once, in the model

Problem 3 needs the longest unbroken vacancy, capped by the owner's maximum
stay. That is a windowed gaps-and-islands query — the kind that gets rewritten
slightly differently by each analyst who needs it.

`int_calendar_days_grouped_into_availability_runs` computes it once. `max_bookable_nights` on the
mart is `least(vacancy length, strictest maximum_nights in that vacancy)`, so
problem 3 reduces to `MAX(max_bookable_nights) GROUP BY listing_id`.

`maximum_nights` is a per-day column and genuinely varies within a listing
here, so the binding constraint is the **minimum** across the run, not the
first value seen.

---

## Materializations

Every model's materialization is a deliberate choice against its grain and its
growth driver, not a layer default applied uniformly.

| Model | Grain | Grows with | Materialization | Why |
| --- | --- | --- | --- | --- |
| `stg_listings` | listing | listings | view | ~50 rows. A rename-and-cast pass; materializing it would copy the source to save nothing. |
| `stg_calendar` | listing-day | **listings × days** | view | The growth driver, but still a thin pass. See the note below on the one condition that changes this. |
| `stg_amenities_changelog` | listing-change | amenity edits | view | ~100 rows, append-only. |
| `int_amenities_versioned` | listing-version | amenity edits | view | Small. Its `LEAD` needs the whole partition per listing, so it can never be built from a slice — an incremental version would compute wrong validity ranges at every boundary. |
| `int_calendar_days_collapsed_to_reservations` | reservation | bookings | view | Collapses ~18k days to ~1.5k stays. Cheap, and only read once. |
| `int_calendar_days_grouped_into_availability_runs` | vacancy run | calendar | view | Gaps-and-islands is **structurally non-incremental**: adding one day can extend, split, or merge an existing run, so any slice-based build corrupts the runs that straddle its edge. Always computed over the full calendar. |
| `listings` | listing | listings | table | ~50 rows. Read by the reporting layer, so it is materialized, but a full rebuild is instant and there is nothing to accumulate. |
| `listing_days` | listing-day | **listings × days** | **incremental** | The only model where incremental is warranted. Reasons below. |

### Why `listing_days` is incremental — retention, not speed

At 18,250 rows a full rebuild takes well under a second, so this is not a
performance optimization. It is a correctness one.

An availability calendar is a **rolling forward window**: the source publishes
roughly the next year per listing, and each day it drops the day that has
passed and adds one at the far end. A table rebuilt from scratch therefore
contains only what the source still publishes — every day that has aged out of
the feed is silently gone. Year-over-year revenue, which is the analysis this
mart exists to serve, needs exactly those forgotten days.

Incremental on `(listing_id, calendar_date)` accumulates them. Verified
directly: a day injected outside the published window survives a subsequent
run untouched, while the published window is fully restated.

**The whole published window is restated each run, not just its leading edge.**
Future days are mutable — a night that is free today is booked tomorrow, and
its price moves until it sells. An append-only `WHERE date > max(date)` pattern
would freeze every day at whatever it looked like when first seen, leaving the
table full of stale availability and understated revenue. That failure is
invisible: the row count grows exactly as expected. `delete+insert` on the
composite key restates in place and leaves aged-out days alone.

`delete+insert` rather than `merge` because `merge` requires a newer DuckDB
than this project pins. The semantics needed here are identical.

### What changes at scale

The derived columns stay correct today because the intermediates are views over
the full staging models, so runs and amenity versions are always computed
against everything the source publishes rather than against the incremental
slice. That is also the design's ceiling. In order, the levers are:

1. **Materialize `stg_calendar` as a table if the source stays a file.** It is
   referenced 15 times across models and tests, and every reference re-parses
   the CSV. Against a warehouse table a view costs nothing, which is why it is
   still a view here — but a file-backed source flips that calculation
   immediately, and this is the first thing to change.
2. **Partition `listing_days` on `calendar_date`** so the restatement predicate
   prunes rather than rewrites the published window wholesale.
3. **Materialize the two calendar intermediates**, which become the expensive
   step once the fact stops being the bottleneck.

## Testing

58 nodes, 55 passing tests, 3 deliberate warnings.

The interesting tests are not the `not_null`s — they are the ones asserting
that the mart's promises hold:

- **`assert_listing_days_preserve_calendar`** — the mart neither gains nor
  loses listing-days against staging, *and* its total revenue still equals the
  sum of prices on reserved nights. The revenue leg is the one that matters: it
  catches any join that quietly adds or removes money.
- **`assert_amenity_versions_do_not_overlap`** — the as-of join is only
  single-valued if validity ranges are disjoint and contiguous. An overlap
  would double-count a day's revenue; a gap would drop it from segmentation.
- **`assert_revenue_only_on_reserved_nights`** — the guarantee that makes
  `SUM(revenue)` safe without a filter.
- **`assert_source_columns_match_contract`** — the raw layer pins column types
  positionally, which is only valid while the CSVs keep the documented column
  order. This asserts that order.

### The three warnings are real findings, not noise

They warn rather than error because each is a source data problem that this
project should surface, not silently repair:

1. **Orphaned listing** — `276450` referenced by calendar and changelog, absent
   from `LISTINGS` (2 `relationships` tests).
2. **Shared reservation id** — reservation `836` appears on two listings on
   2021-07-12, the calendar's first day. Reservation ids are otherwise allocated
   in contiguous per-listing blocks, so this looks like an off-by-one where two
   blocks meet at the boundary.

Full write-up, including the source-type contract and its two unreproducible
types, is in [`docs/source_type_contract.md`](../docs/source_type_contract.md).

---

## Conformance with dbt Labs' structure guide

Reviewed against [How we structure our dbt
projects](https://docs.getdbt.com/best-practices/how-we-structure/1-guide-overview?version=2).

| Convention | Status |
| --- | --- |
| Staging 1:1 with sources, no joins or aggregations | ✅ |
| Staging materialized as views | ✅ |
| Staging entities plural, `stg_` prefixed | ✅ |
| Sources in `_staging__sources.yml` | ✅ |
| Intermediate named `int_[entity]s_[verb]s` | ✅ renamed |
| Intermediate kept out of the production schema | ✅ own schema |
| Marts named for the entity forming the grain, plural | ✅ renamed |
| Marts materialized as tables | ✅ |
| Marts wide and denormalized | ✅ |
| Cascading configs in `dbt_project.yml`, not per-model | ✅ |
| Folders as selectors rather than tags | ✅ |
| YAML config per folder | ⚠️ deviates — see below |

Three things moved during this review:

- **Intermediate models were renamed to verb-final form.**
  `int_reservations` → `int_calendar_days_collapsed_to_reservations`, and
  `int_listing_availability_runs` →
  `int_calendar_days_grouped_into_availability_runs`. Both now mirror the
  guide's own `int_order_items_summed_to_orders` example. They are verbose, but
  the name states the re-graining the model performs, which is the point.

- **Intermediate models moved to a `main_intermediate` schema.** The guide's
  default is ephemeral; its sanctioned alternative is views in a custom schema
  with separate permissions. Ephemeral would have made them un-inspectable,
  which matters here because the amenity SCD2 is the most intricate logic in
  the project. A separate schema keeps them out of the schema analysts browse
  while leaving them queryable.

- **Marts dropped their `fct_`/`dim_` prefixes.** Version 2 of the guide names
  marts for the entity forming the grain rather than by Kimball role, so
  `fct_listing_day` → `listing_days` and `dim_listing` → `listings`. This is
  the change most worth a second opinion: many teams still expect the
  prefixes, and reverting is a rename, not a rework.

### Documented deviations

The guide's closing principle is that consistency matters more than
convention, provided deviations are documented. There are two.

**1. YAML config per model rather than per folder.** Page 5 of the guide
recommends `_[directory]__models.yml` and marks config-per-model as not
recommended — but pages 2 and 4 both *show* per-model YAML
(`stg_orders.yml` alongside `stg_orders.sql`). The guide contradicts itself
here. This project uses per-model files: the source tables carry 20 documented
columns each, and a single staging YAML ran past 200 lines and became the file
nobody wanted to open. Sources remain consolidated in `_staging__sources.yml`
as the guide directs.

**2. `tests/` contains single-model assertions, not only cross-model
integration tests.** The guide reserves singular tests for multi-model
testing. Several here assert one model — composite-key grain, for instance.
That is a consequence of taking no package dependency: `dbt_utils` would
express `unique_combination_of_columns` as a generic test, and these would
collapse into YAML. Worth revisiting if a package is ever added.

### Why the amenity history is a model, not a snapshot

The guide points to snapshots for type-2 slowly changing dimensions, and
`int_amenities_versioned` builds exactly that — so the choice deserves stating.

Snapshots exist to *capture* history that the source does not keep, by polling
a mutable table on a schedule. Here the source already ships the history:
`AMENITIES_CHANGELOG` is the record of every change. A snapshot would begin
tracking from its own first run and would be blind to everything before it,
which is the entire period this data covers. Deriving the validity ranges from
the changelog reconstructs the full history deterministically and rebuilds
identically from scratch.

`LISTINGS` is the table that *would* warrant a snapshot — price, review scores,
and bedroom counts all change at source with no history retained.

---

## What I'd do next

- **Recover listing 276450's ID.** The evidence is strong but circumstantial;
  it needs a source-system confirmation, not a guess in a model.
- **Make `listing_days` incremental** on `calendar_date` once the calendar
  grows beyond a single load.
- **Add an amenity bridge table** (`listing_day × amenity`) if amenity analysis
  broadens beyond a handful of flags — grouping by amenity is awkward against an
  array column.
- **Snapshot `LISTINGS`.** Price, review scores, and bedroom counts all change
  at source with no history kept; today's mart can only ever show their current
  values.
