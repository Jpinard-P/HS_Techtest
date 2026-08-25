"""Fail CI when a new data-quality warning appears.

Three tests are configured to warn rather than error, because each surfaces a
source-data problem this project deliberately reports instead of repairing:

  * the two `relationships` tests on listing 276450, which has calendar and
    amenity history but no row in LISTINGS
  * assert_reservation_covers_one_listing, for reservation 836 appearing
    against two listings

Those are known and documented in docs/source_type_contract.md. A *fourth*
warning means the source data has broken in a new way, which should stop the
build and be looked at -- not scroll past in a log. A warning that disappears is
also reported, since it usually means a test stopped testing anything.
"""

import json
import pathlib
import re
import sys

EXPECTED_WARNINGS = {
    "relationships_stg_calendar_listing_id__listing_id__ref_stg_listings_",
    "relationships_stg_amenities_changelog_listing_id__listing_id__ref_stg_listings_",
    "assert_reservation_covers_one_listing",
}

results_path = pathlib.Path(__file__).resolve().parents[2] / "dbt_project" / "target" / "run_results.json"
if not results_path.exists():
    sys.exit(f"no run_results.json at {results_path} -- did `dbt build` run?")

results = json.loads(results_path.read_text())
def test_name(unique_id: str) -> str:
    """Strip the `test.<project>.` prefix, and the hash dbt appends to long
    generic-test names (`...__ref_stg_listings_.d6be8ef584`)."""
    name = unique_id.split(".", 2)[-1]
    return re.sub(r"\.[0-9a-f]{10}$", "", name)


actual = {
    test_name(r["unique_id"])
    for r in results["results"]
    if r["status"] == "warn"
}

new = sorted(actual - EXPECTED_WARNINGS)
resolved = sorted(EXPECTED_WARNINGS - actual)

for name in new:
    print(f"::error title=New data-quality warning::{name} warned and is not a known issue")
for name in resolved:
    print(f"::warning title=Warning resolved::{name} no longer warns -- update EXPECTED_WARNINGS")

if new:
    sys.exit(
        f"\n{len(new)} new warning(s): {', '.join(new)}\n"
        "Either fix the underlying data issue, or document it and add it to "
        "EXPECTED_WARNINGS in .github/scripts/check_warnings.py."
    )

print(f"OK: {len(actual)} warning(s), all known and documented.")
