# The data story — from three CSVs to three answers

This is the narrative companion to the [README](../README.md) and the
[source type contract](source_type_contract.md). Those documents explain the
project's structure and its raw-layer typing; this one follows the **data
itself**, end to end: what arrives in the three CSVs, every issue found in
them, what is done about each issue (and what is deliberately not done, and
why), how each transformation layer changes the data's shape, how the finished
marts answer the brief's three business questions, and the guardrails that
keep the numbers from being misread or misused.

Read it top to bottom and you have the full script of what happens to a row
between `data/*.csv` and a figure in a stakeholder's report.

---

## 1. What arrives

Three files land in `data/`, described by the source documentation (*Table
Descriptions*, revised January 2026):

| File | Grain | Size | What it claims to be |
| --- | --- | --- | --- |
| `LISTINGS.csv` | one row per listing | 51 rows | Descriptive attributes: name, host, neighborhood, property type, amenities, price "as of the start of the date range in CALENDAR", review fields. `ID` is documented as the primary key. |
| `CALENDAR.csv` | one row per listing per day | 18,252 rows | A year of availability: date, available flag, price, min/max nights, reservation id ("If NULL, there was no reservation on that date"). `(LISTING_ID, DATE)` is documented as the primary key. |
| `AMENITIES_CHANGELOG.csv` | one row per amenity change | 100 rows | Every change to a listing's amenity list: listing, timestamp, the full new list. |

And the brief asks three questions, each with a published figure the pipeline
must reproduce:

1. **Revenue by month, split by air conditioning** — check: 21.2% of July
   2022 revenue comes from listings without AC.
2. **Average price increase per neighborhood, 2021‑07‑12 → 2022‑07‑11** —
   check: Back Bay averages **$44**, from a single listing.
3. **Longest possible stay for listings with a lockbox and a first aid kit**
   — check: listing 1303261, **159** days.

Those three numbers are the acceptance test of everything below — literally:
`tests/assert_published_answers_hold.sql` re-derives all three on every build
and fails if any of them moves.

## 2. Reading the files: the raw layer trusts the documentation, not the sample

The first decision happens before any transformation: **what type is each
column?** DuckDB's CSV sniffer would happily infer types from the current
extract — and it would be wrong the moment the data grows. `BEDROOMS` sniffs
as BIGINT because no listing in this extract is a `"Studio"`; `CALENDAR.PRICE`
sniffs as BIGINT because no price in this extract has cents. The documentation
says both are VARCHAR, and the documentation describes the *feed*, not the
*sample*.

So `models/staging/_staging__sources.yml` pins an explicit `types = [...]`
list on every `read_csv` call. The raw layer reproduces the documented
contract literally, with two deviations the
[source type contract](source_type_contract.md) spells out:

- `DATETIME` columns are stored as `TIMESTAMP` — DuckDB's name for the same
  type; nothing is lost.
- `CALENDAR.RESERVATION_ID` cannot be read as its documented INTEGER as-is,
  because the file writes the four-character string `NULL` in 8,193 of its
  18,252 rows instead of leaving the field empty. The read passes
  `nullstr = ['NULL', '']` so the sentinel becomes a real NULL — a lossless
  reinterpretation of the convention the documentation itself describes.

`assert_source_columns_match_contract` guards this layer: the type pins are
positional, so the test asserts the CSVs still have the documented columns in
the documented order.

## 3. The data issues, and what is done about each

Everything found in the extract, in one ledger. "Fixed in code" always means
the CSVs stay byte-identical — every repair lives in a model where it can be
reviewed, tested, and reverted.

| # | Issue | Disposition | Why |
| --- | --- | --- | --- |
| 1 | `LISTINGS` has 51 rows but its documented primary key, `ID`, is NULL on two of them | One dropped, one repaired — see issues 2 and 3 | The two rows are different problems and are not treated the same way |
| 2 | One NULL-ID row is `TESTING LISTING`: host `-99999`, accommodates 99, price $999.99 | **Dropped in `stg_listings`** | Synthetic. It corresponds to nothing in `CALENDAR` or `AMENITIES_CHANGELOG`, so it can never join to anything downstream |
| 3 | The other NULL-ID row is a real listing whose ID was lost in the extract — meanwhile `CALENDAR` and `AMENITIES_CHANGELOG` both reference listing `276450`, which `LISTINGS` never identifies | **Repaired in `stg_listings`**: the row's ID is restored to `276450` | The identification is a deduction, not a guess — four independent facts converge (§4). It is made in staging rather than in the CSV so the extract stays pristine and the inference stays reviewable; `assert_recovered_listing_matches_its_evidence` re-checks the evidence on every build |
| 4 | `CALENDAR`'s documented `(LISTING_ID, DATE)` key is not unique: listing `1303261` on `2022-07-07` appears three times | **Collapsed with `DISTINCT` in `stg_calendar`** | The three rows are identical in every column, so deduplication loses nothing. `assert_stg_calendar_grain_is_unique` holds the grain from here on |
| 5 | Reservation `836` appears on two listings (`753446` and `801680`) on `2021-07-12`, the calendar's first day | **Not fixed — surfaced as the build's one warning** | Unlike the orphaned listing, the data cannot say which listing the reservation belongs to. Reservation ids are otherwise allocated in contiguous per-listing blocks, so this looks like an off-by-one where two blocks meet at the opening boundary — but "looks like" is not a basis for moving revenue between hosts. `assert_reservation_covers_one_listing` warns, and CI pins the warning so it can neither multiply nor silently vanish |
| 6 | `RESERVATION_ID` writes the string `NULL` instead of an empty field | **Reinterpreted at read time** (`nullstr`) | The documentation already defines NULL as "no reservation"; only the spelling is non-standard |
| 7 | Numbers, dates, and booleans are documented — and delivered — as VARCHAR (`BEDROOMS`, `PRICE`, `AVAILABLE` `'t'`/`'f'`, review fields) | **Cast strictly in staging** (`cast`, not `try_cast`) | A value the contract permits but staging cannot interpret should fail the build loudly, not quietly become a NULL inside a metric |
| 8 | Prices arrive as text with a currency marking (`"$280.00"`) or bare (`CALENDAR`) | **Parsed, not stripped**: the `parse_price` macros split amount from currency symbol, and the symbol resolves to an ISO code via the `currency_symbols` seed | `replace(price, '$', '')` works until the first `€`, then fails with an error that names a symptom. Parsing makes the failure graded: a euro price parses as `EUR` and trips a currency test that names the rows (§8) |
| 9 | The loaded calendar starts and ends mid-month: July 2021 has 20 days of coverage, July 2022 has 11 | **Flagged, not filtered**: every mart row carries `is_complete_month` and `days_of_month_in_calendar` | A partial month next to a full one always reads as a revenue collapse. But the brief's own 21.2% figure is for *partial* July 2022 — filtering upstream would answer a different question than the one asked. The guard belongs in the analyst's hands, visibly |
| 10 | Every amenity change predates the loaded calendar (last change 2021‑07‑06; calendar opens 2021‑07‑12), so amenities are constant across the reporting period | **Versioned anyway** (type‑2, in `int_amenities_versioned`) | A current-state join gives identical numbers today at a fraction of the complexity — and starts silently misattributing revenue the day one change lands inside the calendar. Building the validity ranges now makes that day a data change instead of a remodel |

Two issues in that ledger deserve their fuller stories, because they carry the
project's two most consequential judgment calls: one where the data *could* be
repaired, and one where it could not.

## 4. The orphaned listing: recovered, because the evidence closes

Listing `276450` has 365 calendar days and 2 amenity changes, but the
`LISTINGS` row that describes it arrives with a NULL ID. This is not a
cosmetic problem — it moves a published answer. An inner join from the
calendar to the listings drops those 365 days silently, and with them the
answer to problem 1 shifts from **21.2%** (the brief's figure) to 22.1%. A
single join type, a real revenue difference, no error anywhere.

Two things are done, in order of importance:

**The mart is built on the calendar spine, not the listing.** `listing_days`
starts from every listing-day the calendar knows about and left-joins the
descriptive record, with `has_listing_record` marking any day whose listing
has none. That is what makes an orphan *visible and recoverable* rather than
absent — and it is the design that survives the next orphan, whatever this
extract does.

**The ID is recovered, in staging, on evidence.** Four independent facts
identify the anonymous row as `276450`:

1. **The arithmetic closes.** `CALENDAR` and `AMENITIES_CHANGELOG` each cover
   50 listings; `LISTINGS` identifies 49 and holds two NULL-ID rows, one of
   which is the synthetic test record. Exactly one real row is unidentified;
   exactly one ID is unclaimed.
2. **The price agrees.** The row is priced `$280.00` — unique across all 51
   raw rows — and that is `276450`'s calendar price on the calendar's first
   day, which is precisely what `LISTINGS.PRICE` is documented to mean.
3. **The amenities agree.** Its 28-item amenity set exactly equals `276450`'s
   latest changelog version — the same relationship every one of the 49
   identified listings has with its own latest version. Only one other
   changelog row matches the set at all, and it belongs to a listing already
   identified.
4. **The household agrees.** The row is *"…South End 1BR 1BA **#3**"*; its
   host already owns *"#2"*, the identified sibling unit, in the same
   neighborhood.

Nothing is invented: 19 of the row's 20 columns are real source data — only
the ID is inferred. The repair moves **no published answer** (the listing is
in Roxbury, so Back Bay's $44 stands; its amenities resolve through the
changelog either way, so 21.2% stands). One unpublished number moves
deliberately: Roxbury's problem‑2 average now includes its 13th listing.

Because it remains an inference rather than a source-system confirmation, the
evidence is a **test**, not a comment:
`assert_recovered_listing_matches_its_evidence` re-verifies all of it on every
build, so a future extract that changes the row fails the build instead of
being mislabelled. Confirming the ID with the source system is the first item
on the project's follow-up list.

## 5. The shared reservation: surfaced, because the evidence does not

Reservation `836` sits on two different listings — `753446` and `801680` — on
the calendar's first day, and it is the *only* reservation on `753446`.
Reservation ids are otherwise allocated in contiguous per-listing blocks
(listing `3781` holds ids 1–41, `5506` holds 42–89), so this looks like an
off-by-one where two blocks meet at the opening boundary — but nothing in the
data says *which* of the two listings the reservation truly belongs to.
Repairing it would mean moving a night of revenue between two hosts on a
hunch.

So it is not repaired. `assert_reservation_covers_one_listing` **warns** —
deliberately warns rather than errors, because this is a source-data problem
the pipeline should report upward, not a modelling failure that should stop
the build. And because a warning that scrolls past unread is worthless, CI's
`check_warnings.py` pins the warning set to a documented allowlist: a *new*
warning fails the build, and so does a *disappeared* one (which usually means
a test quietly stopped testing anything). This warning is the build's only
one, and it is load-bearing: it is the message to the source system's owners.

This is the project's dividing line in one pair: **issue 4 is repaired
because the evidence is conclusive; issue 5 is surfaced because it is not.**
Fixes are for what the data proves; everything else is made loud.

## 6. The transformations: what each layer does to a row

### Staging (`main_staging`, views) — same grain, honest types

One model per source file. No joins between sources, no aggregation, no grain
change — this layer only makes the data mean what it says:

- **`stg_listings`** restores `276450`'s ID (§4), drops the test record,
  renames every column, casts the VARCHAR-documented numbers and dates
  strictly, parses `PRICE` into `listing_price` + `listing_price_currency`,
  and turns the JSON-ish `AMENITIES` and `HOST_VERIFICATIONS` strings into
  real arrays.
- **`stg_calendar`** collapses the duplicate triplet (§3, issue 4), turns
  `'t'`/`'f'` into a real BOOLEAN, narrows `DATE` from midnight-timestamps to
  a DATE, and parses the price the same way.
- **`stg_amenities_changelog`** renames, types, and arrays — the changelog is
  clean.

The one join in the layer is to the `currency_symbols` **seed** —
project-owned reference data, not a second source.

### Intermediate (`main_intermediate`, views) — the hard problems, solved once

Three models, each named for the re-graining it performs:

- **`int_amenities_versioned`** turns the changelog into type‑2 versions with
  half-open `[valid_from, valid_to)` validity ranges, so any day joins to
  exactly one amenity set — the one actually in force that day. Each
  listing's first version is backdated to `-infinity`, because a changelog
  records *changes*, not origins; the alternative leaves NULL amenities on
  early days, which drop out of segmentations without announcing themselves.
- **`int_calendar_days_collapsed_to_reservations`** collapses ~18k
  calendar days into ~1.5k contiguous stays.
- **`int_calendar_days_grouped_into_availability_runs`** solves
  gaps-and-islands once: contiguous vacancy runs, each carrying
  `max_bookable_nights = least(run length, strictest maximum_nights in the
  run)`. The *minimum* of `maximum_nights` across the run, because the limit
  is per-day and the binding constraint is the strictest one a stay would
  cross.

These layers live in their own schemas, out of the analyst contract but fully
queryable — a wrong number in a mart can be traced one layer at a time.

### Marts (`main`, tables) — the analyst contract

- **`listing_days`** — one row per listing per calendar day, the reporting
  fact. Built from the calendar spine outward (§4), it denormalizes the
  listing attributes, resolves amenities as of each day, attaches the
  vacancy-run and reservation context, and carries the guardrail columns
  described in §8. It is the only incremental model, and the reason is
  **retention, not speed**: an availability calendar is a rolling forward
  window, and a table rebuilt from scratch forgets every day the feed has
  dropped — exactly the days year-over-year analysis needs. The whole
  published window is restated each run (future days are mutable: free today,
  booked tomorrow), while aged-out days are left untouched.
- **`listings`** — one row per listing, calendar totals rolled up from
  `listing_days` so they inherit the retained history.
- **`reservations`** — one row per stay, aggregated from the mart for the
  same reason.
- **`hosts`** — one row per host, rolled up from `listings`.

## 7. How the marts answer the three questions

Each answer is a short query in `analyses/`, because the mart has already done
the dangerous parts.

**Problem 1 — revenue by month, by air conditioning** (`analyses/01`).
`SUM(revenue) GROUP BY month, has_air_conditioning`. The mart contributes
three protections: `revenue` is already zero on unbooked nights, so asking
prices cannot leak into takings; `has_air_conditioning` is resolved *as of
each day* through the version ranges, so the query keeps working the day an
amenity change lands inside the calendar; and `is_complete_month` rides along
in the output — surfaced, not filtered, because the published 21.2% is itself
a partial-month figure. **Returns 21.2%.**

**Problem 2 — average price increase per neighborhood** (`analyses/02`).
The two dates, 2021‑07‑12 and 2022‑07‑11, are **parameters of the question,
pinned as literals in the query** — not derived from the calendar's extent,
even though the two coincide in this extract. Derived endpoints mean loading
one more day of calendar silently changes the answer to a question that named
its own dates. The measure is `nightly_price`, not `revenue` — this is a
question about asking prices, and revenue would score every vacant night as a
price of zero. The average is per-listing first, then across listings, so a
listing counts once regardless of calendar coverage. **Returns $44 for Back
Bay.**

**Problem 3 — longest possible stay, lockbox + first aid kit**
(`analyses/03`). `MAX(max_bookable_nights)` per listing over days where
`has_lockbox AND has_first_aid_kit` — the gaps-and-islands work is already in
the mart. The amenity filters are exact `list_contains` matches, never `LIKE`:
the vocabulary contains *Lock on bedroom door* alongside *Lockbox* (and *Hair
dryer* alongside *Air conditioning*), so pattern matching over-counts
quietly. Runs touching the calendar's edge are flagged as lower bounds, since
the vacancy may continue beyond the loaded data. **Returns 159 for listing
1303261.**

## 8. How the design prevents misuse

Most wrong numbers in analytics are not bugs; they are correct queries against
data that meant something other than what the analyst assumed. The mart is
designed so that the natural query is the correct one, and every assumption an
analyst might silently make is either made safe or made visible:

- **`SUM(revenue)` is safe without a filter.** `revenue` is the price on
  booked nights and `0` on vacant ones; `nightly_price` is the asking price
  every night. The overstatement trap — summing asking prices as takings —
  is closed by the schema instead of by every analyst's memory, and
  `assert_revenue_only_on_reserved_nights` enforces the relationship.
- **Amenity questions are exact-match by construction.** The `has_*` flags
  encode `list_contains`, and the full `amenities` array is on every row so
  any other amenity is testable the same safe way.
- **Point-in-time is the default, not an option.** Amenities on a row are the
  amenities *of that day*. There is no current-state amenity column on the
  fact to reach for by mistake.
- **Partial periods announce themselves.** `is_complete_month` and
  `days_of_month_in_calendar` sit on every row, so a July-2022 "collapse" is
  one column away from its explanation — and the choice to exclude a stub is
  the analyst's, made visibly.
- **Provenance gaps are flagged, not absorbed.** `has_listing_record` marks
  any calendar day whose listing has no descriptive record; today it is true
  everywhere, and it exists so the next orphan becomes a flagged row rather
  than a silent absence. Analysis 2 shows the intended pattern: guard on the
  flag explicitly.
- **Currency is a fact, not an assumption.** Every price row carries
  `price_currency`, and `assert_prices_share_one_currency` fails the build on
  the first non-USD price — because a `SUM` across currencies is not a
  number, and the decision to convert, filter, or segment belongs to a
  person.
- **Business dates cannot drift with the data.** No model hardcodes a date;
  every coverage flag is computed from the calendar's own extent at run time.
  Question parameters live pinned in the analyses that ask them. Neither can
  contaminate the other — and the coverage columns are named for the
  *calendar* (`days_of_month_in_calendar`, `available_run_touches_calendar_edge`)
  rather than for a "window", precisely so nobody reads them as a business
  period.
- **Edge effects are labelled.** `available_run_touches_calendar_edge` marks
  stays that are lower bounds, not measurements.
- **The published answers are a contract.** `assert_published_answers_hold`
  pins 21.2%, $44, and 159 as build-breaking tests, re-derived independently
  of the analyses so the two cannot drift into agreeing while both being
  wrong. A legitimate data refresh updates the expectations deliberately, in
  the same commit.
- **The browser cannot write.** The Streamlit explorer (`app/explorer.py`)
  opens read-only, per-query connections: stakeholders can query, chart, and
  export, and cannot alter the database or block a build.
- **The warning channel stays credible.** One warning exists, it is a real
  finding (§5), and CI fails on any new or vanished warning — so a warning in
  this project is always news, never wallpaper.

## 9. Who this serves, and how

- **Stakeholders with the three questions** get their answers in
  `analyses/`, each reproducing its published check, each commented with what
  the mart is doing on its behalf. The explorer gives the same audience
  self-serve access — presets for the three problems, schema-aware SQL, chart
  builder, CSV export — against the same marts, so the number in a meeting
  and the number in the pipeline are the same number.
- **Analysts** work against four documented marts in the `main` schema, wide
  and denormalized, where the safe query is the easy query. Every column and
  every test carries a description that renders in the dbt docs site, so the
  reasoning travels with the schema rather than living in someone's head.
- **Data engineers** get a pipeline that rebuilds deterministically from the
  CSVs, a CI run that needs no warehouse or secrets, and 55 tests curated so
  that every one of them can actually fail — a red build always means
  something.
- **The source system's owners** get a precise defect list: the ledger in
  §3, the standing warning on reservation `836`, and one open question —
  confirm `276450`. The extract itself is never touched, so their files remain
  the ground truth to diff against.

The through-line of the whole pipeline is a single principle: **repair only
what the data proves, flag what it cannot, and make every remaining sharp
edge visible at the point of use.** The three published figures are
reproduced not by tuning to them, but by making the choices — spine joins,
point-in-time amenities, exact matches, pinned dates — that turn out to be
the ones the figures require.
