#!/usr/bin/env python3
"""End-to-end importer pipeline test.

Creates fresh databases, boots the backend, drives the real catalog and
MyFitnessPal importer CLIs, and asserts:

* the import is idempotent — rerunning leaves the logical state unchanged, and
* two independent fresh databases produce identical logical state,
* the specific importer regressions this suite guards against stay fixed.

This is the single large test for the importers. It requires Postgres, the Rust
toolchain, and the project dev shell (``just test-importers-e2e``).
"""

from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from harness import (
    Backend,
    FreshDatabase,
    query,
    run_catalog_import,
    run_personal_import,
    snapshot,
)


class ImportPipelineE2E(unittest.TestCase):
    def test_import_is_idempotent_and_deterministic(self) -> None:
        snapshots: dict[str, str] = {}

        for label in ("a", "b"):
            with (
                FreshDatabase(label) as database,
                Backend(database.url) as backend,
                tempfile.TemporaryDirectory(prefix=f"calco-e2e-{label}-") as tmp,
            ):
                work_dir = Path(tmp)
                run_catalog_import(backend, work_dir)
                run_personal_import(backend, work_dir)
                self._assert_regressions(database.url, work_dir)
                snapshots[label] = snapshot(database.url)

                if label == "a":
                    # Rerun the whole pipeline on the same database.
                    run_catalog_import(backend, work_dir)
                    run_personal_import(backend, work_dir)
                    self._assert_regressions(database.url, work_dir)
                    assert snapshots[label] == snapshot(database.url), (
                        "import pipeline is not idempotent"
                    )

        assert snapshots["a"] == snapshots["b"], (
            "two fresh databases produced different import results"
        )

    def _assert_regressions(self, database_url: str, work_dir: Path) -> None:
        # Total catalog + private products: 5 merged catalog foods plus the two
        # private foods created from the unmatched MFP rows.
        assert query(
            database_url,
            "SELECT count(*)::text FROM products WHERE deleted_at IS NULL",
        ) == ["7"]

        # Merge deduplicates same-unit servings, keeping the first conversion.
        assert query(
            database_url,
            "SELECT ps.unit||'|'||round(ps.grams_per_unit)::int::text "
            "FROM product_servings ps JOIN products p ON p.id = ps.product_id "
            "WHERE p.source = 'USDA' AND p.source_id = '1001' ORDER BY ps.unit",
        ) == ["cup|150", "serving|100"]

        # Merge groups cross-source barcodes onto the canonical source.
        assert query(
            database_url,
            "SELECT barcode FROM products "
            "WHERE source = 'USDA' AND source_id = '1002'",
        ) == ["11111111"]
        assert query(
            database_url,
            "SELECT count(*)::text FROM products "
            "WHERE source = 'OFF' AND source_id = '8900001'",
        ) == ["0"]

        # create_foods normalizes the legacy serving shape from the fixture.
        assert query(
            database_url,
            "SELECT ps.unit||'|'||round(ps.grams_per_unit)::int::text "
            "FROM product_servings ps JOIN products p ON p.id = ps.product_id "
            "WHERE p.source = 'USER' AND p.name = 'Mystery Custom Food'",
        ) == ["serving|200"]

        # History import skips the value <= 0 row and uses the preserved serving
        # correction (120 g) for the remaining Test Apple row.
        assert query(
            database_url,
            "SELECT count(*)::text||'|'||"
            "round(coalesce(sum(quantity), 0))::int::text "
            "FROM food_logs WHERE item_name = 'Test Apple'",
        ) == ["1|120"]

        # The trailing-space description was matched to the existing serving
        # review entry, so the manual correction survives step 9 regeneration.
        step9 = work_dir / "step-9-out-serving-review.csv"
        with step9.open(newline="", encoding="utf-8") as handle:
            review = {row["description"].strip(): row for row in csv.DictReader(handle)}
        assert review["Test Apple"]["corrected_serving_grams"] == "120"


if __name__ == "__main__":
    unittest.main(verbosity=2)
