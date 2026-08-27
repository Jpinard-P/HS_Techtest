# Rental analytics — data model

[![dbt CI](https://github.com/Jpinard-P/HS_Techtest/actions/workflows/ci.yml/badge.svg)](https://github.com/Jpinard-P/HS_Techtest/actions/workflows/ci.yml)

A dbt project over three source files (`LISTINGS`, `CALENDAR`,
`AMENITIES_CHANGELOG`) that produces a day/listing mart for revenue,
occupancy, and point-in-time amenity analysis.

For the end-to-end narrative — every data issue in the extract, what is done
about each (and what deliberately isn't), how each layer transforms the data,
how the marts answer the brief's three questions, and the guardrails against
misuse — see [`docs/data_story.md`](docs/data_story.md).

```
models/
├── staging/                    views · schema: main_staging
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
    ├── listings.sql/.yml               ← one row per listing
    ├── reservations.sql/.yml           ← one row per stay
    └── hosts.sql/.yml                  ← one row per host

seeds/currency_symbols.csv/.yml         currency symbol → ISO code lookup
macros/parse_price.sql                  price text → amount + currency symbol
```

Verify with:

```bash
dbt build      # 66 nodes, 0 errors, 1 intentional warning (below)
dbt compile    # analyses are NOT compiled by `build` -- a broken one ships green
```

Both run in CI on every push and pull request — see
[Continuous integration](#continuous-integration).

**Run everything from the repo root**, dbt and ad-hoc DuckDB sessions alike:

```bash
duckdb data/dev.duckdb
```

The staging and intermediate models are views over the CSVs, and the `read_csv`
paths stored in those views are relative. DuckDB resolves them against the
working directory of whichever process runs the query — not against the
location of `dev.duckdb`, and not against wherever dbt ran when it built the
view. Opening the database from anywhere else fails on the first query that
touches a view:

```
IO Error: No files found that match the pattern "data/AMENITIES_CHANGELOG.csv"
```

If you need to work from another directory, `SET
file_search_path='/path/to/repo'` in the session. The marts are tables, so they
hold real data and query fine from anywhere; it is only the views that reach
back to the CSVs.

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

## Exploring the mart in a browser

`app/explorer.py` is a small Streamlit app over `data/dev.duckdb`: a SQL
editor on a **read-only** connection with schema-aware autocomplete (it
completes the live database's table and column names, not just keywords),
preset queries (the three business problems plus revenue/occupancy cuts),
the table list per schema, CSV download, and a point-and-click chart
builder for any result.

```bash
pip install -r app/requirements.txt   # separate from the dbt requirements
streamlit run app/explorer.py         # from the repo root, after dbt build
```

Connections are opened per query and read-only, so the app cannot write and
only holds the database lock briefly — `dbt build` still works while the app
is open. Its dependencies live in `app/requirements.txt` so CI and the dbt
toolchain never install a web stack they don't use.

---

## The decisions that matter

Each of these is told in full — evidence, alternatives, and consequences — in
[`docs/data_story.md`](docs/data_story.md). This is the short form.

### 1. `listing_days` is built on the calendar, not the listing

Listing `276450` has 365 calendar days and 2 amenity changes, but the
`LISTINGS` row describing it arrives with a NULL ID. An inner join from the
calendar to the raw listings drops those days silently — and moves problem
1's answer from **21.2%** (the published figure) to 22.1%. So the fact is
built from the calendar spine outwards, and `has_listing_record` marks any
row whose listing has no descriptive record: an orphan is a flagged row,
never a silent absence.

The ID itself is recovered in `stg_listings` — in code, not in
`data/LISTINGS.csv`, so the extract stays byte-identical and the inference
stays reviewable. Four independent facts identify the row (the counts close
on exactly one unclaimed ID; its unique `$280.00` price equals `276450`'s
opening calendar price; its amenity set equals `276450`'s latest changelog
version; its host owns the sibling unit *"#2"* and this row is *"#3"*), and
`assert_recovered_listing_matches_its_evidence` re-checks all of them on
every build. Recovering it moves no published answer. The full evidence is
in the data story, §4.

### 2. Amenities are type-2 versioned, even though nothing needs it yet

Every amenity change predates the loaded calendar, so a current-state join
produces identical numbers today at a fraction of the complexity — and it is
still the wrong choice. The first change that lands inside the calendar makes
that shortcut attribute pre-change revenue to post-change amenities,
silently. `int_amenities_versioned` builds half-open `[valid_from,
valid_to)` ranges and the mart resolves amenities as of each specific day,
so that day becomes a data change rather than a rebuild. Each listing's
first version is backdated to `-infinity`: a changelog records changes, not
origins, and NULL amenities on early days would drop out of segmentations
without announcing themselves.

### 3. `revenue` and `nightly_price` are separate columns

`CALENDAR.PRICE` exists on every row, booked or not. Summing it gives
*potential* revenue and overstates takings by roughly the vacancy rate.

Rather than rely on every analyst remembering a `WHERE is_reserved` clause,
the mart carries both: `nightly_price` (what was asked, every night) and
`revenue` (what was earned — the price when booked, `0` when not). `SUM(revenue)`
is correct over any combination of days, listings, and months without a filter.
A test enforces the relationship between them.

### 4. Analysis periods live in analyses, not in the model

Problem 2's dates — 2021-07-12 and 2022-07-11 — are parameters of one
business question; the calendar's extent is a property of the data. The two
coincide in this extract, and conflating them means loading one more day of
calendar silently changes the answer to a question that named its own dates.
So the dates are pinned as literals in `analyses/02` (and, independently, in
the golden-answer test) — literals rather than project `vars`, because a
question that names its own dates should name them in the file the reader is
already looking at. **No model hardcodes a date**: every coverage flag is
computed against the calendar's own extent at run time, so extending the
calendar corrects them without a code change.

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

### 7. Prices carry their currency, parsed rather than assumed

The documentation says every price is USD, and `replace(price, '$', '')`
works — until the first `€`, when the strict cast breaks the build with an
error naming a symptom rather than the problem. The `parse_price` macros
instead split every price into its amount (cast strictly) and its currency
symbol, matched with `\p{Sc}` — the Unicode *currency symbol* class — and
resolved to an ISO code against the `currency_symbols` seed. The failure
modes are graded: a `€` price parses as `EUR` with no code change, a symbol
the seed does not map fails `not_null` **naming the rows**, and a non-price
still fails the cast loudly. On top, `assert_prices_share_one_currency`
fails the build on the first non-USD price: a `SUM` across currencies is not
a number, and the choice to filter, convert, or segment must be made by a
person, not defaulted to a mixed-unit total.

### 8. Gaps-and-islands is solved once, in the model

Problem 3 needs the longest unbroken vacancy, capped by the owner's maximum
stay. That is a windowed gaps-and-islands query — the kind that gets rewritten
slightly differently by each analyst who needs it.

`int_calendar_days_grouped_into_availability_runs` computes it once. `max_bookable_nights` on the
mart is `least(vacancy length, strictest maximum_nights in that vacancy)`, so
problem 3 reduces to `MAX(max_bookable_nights) GROUP BY listing_id`.

`maximum_nights` is a per-day column and varies across a listing's calendar
(though within no single run of this extract), so the binding constraint is
the **minimum** across the run, not the first value seen. `minimum_nights` is
deliberately not part of the formula — problem 3 asks for availability windows
and maximum limits only — see *What I'd do next* for what that leaves on the
table.

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
| `reservations` | stay | bookings | table | Aggregated from `listing_days`, not staging, so it inherits the incremental mart's retained history and its revenue is a straight sum of the mart's — a rebuild re-aggregates the mart, not the source window. |
| `hosts` | host | hosts | table | ~36 rows, rolled up from `listings` so per-listing occupancy and revenue are computed once, there. |

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
   referenced 17 times across models and tests, and every reference re-parses
   the CSV. Against a warehouse table a view costs nothing, which is why it is
   still a view here — but a file-backed source flips that calculation
   immediately, and this is the first thing to change.
2. **Partition `listing_days` on `calendar_date`** so the restatement predicate
   prunes rather than rewrites the published window wholesale.
3. **Materialize the two calendar intermediates**, which become the expensive
   step once the fact stops being the bottleneck.

## Testing

66 nodes, 55 tests — 54 passing, 1 deliberate warning.

The suite deliberately excludes tests that cannot fail. A `not_null` on
`has_listing_record` (`x is not null` never returns NULL), on `valid_to`
(`coalesce` with a literal), on `row_number()` or `count(*)`, on a column the
model already filters to non-null, or on a column whose only NULL path is
already guarded upstream — none of these can ever go red. A test that cannot
fail is not coverage; it is a line in a report that trains people to skim.

Every test carries a `description`, so the reasoning is visible in the docs
site and in `manifest.json` rather than only in a comment above the query.
Singular tests are documented in
[`tests/_tests__singular.yml`](tests/_tests__singular.yml) via dbt's
`data_tests` block; generic tests carry theirs inline in each model's `.yml`.
Each description says what breaks if the test fails, which is the part that is
not readable from the SQL.

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

### The remaining warning is a real finding, not noise

Reservation `836` appears on two listings on the calendar's first day, and —
unlike the orphaned listing — nothing in the data says which one it belongs
to, so the test **warns** rather than repairs: a source-data problem this
project surfaces upward instead of fixing on a hunch (the full story is in
the data story, §5). It is the only warning. The two `relationships` tests
on `stg_calendar` and `stg_amenities_changelog` **error** rather than warn:
every listing they reference resolves in `stg_listings`, so a broken foreign
key means the extract has changed in a way nobody has looked at, and should
stop the build.

The raw layer's typing rules, and the two places they deviate from the
source documentation, are in
[`docs/source_type_contract.md`](docs/source_type_contract.md).

---

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request to `main`.
Because the whole project runs on DuckDB against CSVs committed to the repo,
CI needs no warehouse, no credentials, and no secrets — a run is a full
rebuild from empty, which is exactly the thing local development stops
exercising once a `dev.duckdb` exists.

| Step | Catches |
| --- | --- |
| `dbt parse --no-partial-parse` | Deprecations and YAML errors that a warm partial parse hides |
| `dbt build` | Model failures and all 55 tests, including the golden-answer guard |
| `check_warnings.py` | A *new* data-quality warning appearing |
| `dbt compile` | Broken analyses — **`build` does not compile them** |
| `dbt docs generate` | A docs site that no longer builds |

Two of those steps exist because of specific things that went wrong here.

**`dbt compile` is a separate step** because `dbt build` does not compile
analyses. A missing var once broke `02_neighborhood_price_increase` while the
full 58-node suite stayed green; it surfaced only on a manual rebuild from an
empty database. CI now runs both.

**`check_warnings.py` pins the known warning.** One test warns rather than
errors, because it reports a source-data problem this project deliberately
surfaces instead of repairing. The risk with warnings is that they become
wallpaper — a second one scrolls past unread. The script compares the warning
set against a documented allowlist and fails the build on anything new, while
also flagging a *disappeared* warning, which usually means a test quietly
stopped testing anything.

It runs *directly* after `dbt build` because every dbt command overwrites
`target/run_results.json`, and only the test-running ones record test results.
With `dbt compile` or `dbt docs generate` in between, the script would read a
results file in which every test reports "success" without having run, and
pass on nothing — so it asserts the results came from a build rather than
trusting the step order.

There is deliberately **no CD half**: there is no production warehouse to
deploy to, and a deploy job with nothing behind it is theatre. When there is
one, it is a `dbt build --target prod` job gated on this workflow passing.

### The golden-answer test

`assert_published_answers_hold` pins all three published figures — 21.2%, $44,
159 — as a build-breaking test. They are re-derived independently of
`analyses/` rather than read from it, so the test and the query can't drift
into agreeing with each other while both being wrong.

These assert facts about *this extract*, not invariants of the model. If the
source data is legitimately refreshed, the expected values are meant to be
updated deliberately, in the same commit that refreshes the data.

---

## Conformance with dbt Labs' structure guide

Reviewed against [How we structure our dbt
projects](https://docs.getdbt.com/best-practices/how-we-structure/1-guide-overview?version=2).

| Convention | Status |
| --- | --- |
| Staging 1:1 with sources, no joins or aggregations | ✅ the one join is to the currency_symbols seed — a project-owned lookup, not a second source |
| Staging materialized as views | ✅ |
| Staging named `stg_[source]__[entity]s` | ⚠️ `stg_listings`, not `stg_raw__listings` — with a single source, the `__[source]` infix disambiguates nothing |
| Sources in `_staging__sources.yml` | ✅ |
| Intermediate named `int_[entity]s_[verb]s` | ✅ renamed |
| Intermediate kept out of the production schema | ✅ own schema |
| Marts named for the entity forming the grain, plural | ✅ renamed |
| Marts materialized as tables | ✅ |
| Marts wide and denormalized | ✅ |
| Cascading configs in `dbt_project.yml`, not per-model | ✅ |
| Folders as selectors rather than tags | ✅ |
| YAML config per folder | ⚠️ deviates — see below |

Three conventions worth spelling out:

- **Intermediate models are named in verb-final form** —
  `int_calendar_days_collapsed_to_reservations`,
  `int_calendar_days_grouped_into_availability_runs` — mirroring the guide's
  own `int_order_items_summed_to_orders` example. They are verbose, but the
  name states the re-graining the model performs, which is the point.

- **Staging and intermediate models live in their own schemas**
  (`main_staging`, `main_intermediate`), so `main` — the schema analysts
  browse — holds only the two marts. The guide's default for intermediate is
  ephemeral; its sanctioned alternative is views in a custom schema with
  separate permissions. Ephemeral would make these layers un-inspectable,
  which matters because the amenity SCD2 is the most intricate logic in the
  project; separate schemas keep them out of the analyst contract while
  leaving every layer queryable, so a wrong number in a mart can be traced
  one layer at a time.

- **Marts carry no `fct_`/`dim_` prefixes.** Version 2 of the guide names
  marts for the entity forming the grain rather than by Kimball role — hence
  `listing_days` and `listings` rather than `fct_listing_day` and
  `dim_listing`. This is the choice most worth a second opinion: many teams
  still expect the prefixes, and reverting is a rename, not a rework.

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

- **Confirm listing 276450's ID with the source system.** The ID is recovered
  in `stg_listings` and pinned by a test, but the evidence is circumstantial —
  four facts that all point one way, not a record from upstream. A one-line
  confirmation would turn the deduction into a fact.
- **Fold `minimum_nights` into bookability.** `max_bookable_nights` applies
  problem 3's two constraints — the vacancy's length and the owner's maximum —
  and deliberately not the minimum. 58 vacancies in this extract are shorter
  than their own `minimum_nights` (listing `1167987`'s longest, 73 nights,
  sits under a 91-night minimum), so a stakeholder reading the column as "a
  stay this long is offered" needs `minimum_nights`, which the mart carries
  per day. A `meets_minimum_stay` flag on the run would make that check
  one column instead of two.
- **Add an amenity bridge table** when amenity analysis broadens beyond the
  three flag columns. Grain: one row per `(listing_id,
  amenity_version_number, amenity)` — `int_amenities_versioned` unnested,
  ~3,000 rows today. The value is making the amenity a first-class row
  instead of an array element: `GROUP BY amenity` across the 81-value
  vocabulary answers "which amenities correlate with occupancy or price?"
  without each analyst writing their own `unnest`, and joining to
  `listing_days` on listing and version keeps every cut point-in-time
  correct. Deliberately not built yet: the flag columns cover every amenity
  question actually asked, and each mart is a contract to test and maintain
  — the bridge earns its keep the first time someone asks about an amenity
  that has no flag.
- **Snapshot `LISTINGS`.** Price, review scores, and bedroom counts all change
  at source with no history kept; today's mart can only ever show their current
  values.
