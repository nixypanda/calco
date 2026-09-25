"""Tests for Step 8: canonicalize_food_descriptions."""

import csv
import os
import tempfile
import unittest

from steps.canonicalize_food_descriptions import run

EXPECTED_EGG_ROWS = 2

BASE = [
    "item_type", "date", "description", "value", "unit", "serving", "meal",
    "calories", "fat_g", "saturated_fat_g", "trans_fat_g",
    "polyunsaturated_fat_g", "monounsaturated_fat_g", "cholesterol_mg",
    "sodium_mg", "carbs_g", "fiber_g", "sugar_g", "protein_g",
    "vitamin_d_pct_daily_value", "calcium_mg", "iron_pct_daily_value",
    "potassium_mg", "vitamin_a_pct_daily_value", "vitamin_c_pct_daily_value",
    "is_pseudo_gram", "macro_mismatch",
]


def _write_csv(rows: list[dict], fieldnames: list[str] | None = None) -> str:
    if fieldnames is None:
        fieldnames = list(rows[0].keys())
    with tempfile.NamedTemporaryFile("w", newline="", delete=False, suffix=".csv") as f:
        f.write("test export," * (len(fieldnames) - 1) + "test export\n")
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
        return f.name


def _row(**overrides: str) -> dict[str, str]:
    row = dict.fromkeys(BASE, "")
    row.update({
        "item_type": "Foods",
        "date": "2024-01-01",
        "description": "Test Food",
        "value": "1",
        "unit": "serving",
        "serving": "1.0 serving",
        "meal": "Lunch",
        "calories": "100",
        "fat_g": "2",
        "carbs_g": "10",
        "protein_g": "5",
        "is_pseudo_gram": "FALSE",
        "macro_mismatch": "FALSE",
    })
    row.update(overrides)
    return row


class CanonicalizeFoodDescriptionsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for path in [self.input_path, self.output_path]:
            if path and os.path.exists(path):
                os.unlink(path)

    def _run(self, rows: list[dict[str, str]]) -> dict:
        self.input_path = _write_csv(rows, list(rows[0].keys()))
        with tempfile.NamedTemporaryFile(delete=False, suffix=".csv") as handle:
            self.output_path = handle.name
        return run(self.input_path, self.output_path)

    def _read_output(self) -> list[dict[str, str]]:
        with open(self.output_path, newline="", encoding="utf-8") as f:
            f.readline()
            return list(csv.DictReader(f))

    def test_simple_rename_rules_apply(self) -> None:
        result = self._run([
            _row(description="1 Hard Boiled"),
            _row(description="Eggs, boiled"),
            _row(description="Homemade", unit="g", serving="1.0 Gram"),
        ])
        out = self._read_output()
        assert [row["description"] for row in out] == [
            "Egg White",
            "Egg, boiled",
            "Kala Chana Masala",
        ]
        assert result["rows_renamed"] == len(out)

    def test_combined_egg_row_is_expanded(self) -> None:
        result = self._run([
            _row(
                description="5 Egg Whites and 1 Whole Egg",
                serving="1.0 cup",
                calories="145",
                fat_g="5",
                carbs_g="2",
                protein_g="23",
            )
        ])
        out = self._read_output()
        assert len(out) == EXPECTED_EGG_ROWS
        assert [row["description"] for row in out] == ["Egg White", "Egg, boiled"]
        assert out[0]["value"] == "5"
        assert out[1]["value"] == "1"
        assert result["combined_rows_expanded"] == 1

    def test_non_food_rows_are_unchanged(self) -> None:
        result = self._run([
            _row(item_type="Measurement", description="weight", unit="kg"),
        ])
        out = self._read_output()
        assert out[0]["description"] == "weight"
        assert result["rows_renamed"] == 0


if __name__ == "__main__":
    unittest.main()
