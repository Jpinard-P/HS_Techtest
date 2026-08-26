"""Fail CI when a new data-quality warning appears.

One test is configured to warn rather than error, because it surfaces a
source-data problem this project reports instead of repairing:

  * assert_reservation_covers_one_listing, for reservation 836 appearing
    against two listings

It is known and documented in docs/source_type_contract.md. A *second* warning
means the source data has broken in a new way, which should stop the build and
be looked at -- not scroll past in a log. A warning that disappears is also
reported, since it usually means a test stopped testing anything.

The allowlist is meant to shrink by fixing causes, not to grow by absorbing
them: a warning belongs here only while the underlying source problem genuinely
cannot be resolved from the data.
"""

import json
import pathlib
import re
import sys

EXPECTED_WARNINGS = {
    "assert_reservation_covers_one_listing",
}

results_path = pathlib.Path(__file__).resolve().parents[2] / "target" / "run_results.json"
if not results_path.exists():
    sys.exit(f"no run_results.json at {results_path} -- did `dbt build` run?")

results = json.loads(results_path.read_text())

# Every dbt command rewrites run_results.json, but only `build` and `test`
# actually run the tests. `dbt compile` writes a file in which every node --
# tests included -- reports status "success" without having executed, so the
# warn-set below would be empty and this check would trivially "pass". Assert
# the results came from a command that ran the tests, rather than assuming
# nothing ran between `dbt build` and this script.
which = results.get("args", {}).get("which")
if which not in {"build", "test"}:
    sys.exit(
        f"{results_path} was written by `dbt {which}`, which runs no tests.\n"
        "This check must run directly after `dbt build` -- see the step comment "
        "in .github/workflows/ci.yml."
    )

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
