"""Tests for Step 9: generate_serving_review."""

import csv
import os
import tempfile
import unittest

from mfp_nutrients import REQUIRED_REVIEW_REFERENCE_COLUMNS
from steps.generate_serving_review import run

BASE = [
    "item_type", "date", "description", "value", "unit", "serving", "meal",
    "calories", "fat_g", "carbs_g", "protein_g",
    "fiber_g", "sugar_g", "saturated_fat_g", "trans_fat_g",
    "monounsaturated_fat_g", "polyunsaturated_fat_g", "cholesterol_mg",
    "sodium_mg", "calcium_mg", "potassium_mg",
    "vitamin_d_pct_daily_value", "iron_pct_daily_value",
    "vitamin_a_pct_daily_value", "vitamin_c_pct_daily_value",
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
        "value": "100",
        "unit": "g",
        "serving": "100.0 g",
        "meal": "Lunch",
        "calories": "300",
        "fat_g": "10",
        "carbs_g": "30",
        "protein_g": "15",
    })
    row.update(overrides)
    return row


class GenerateServingReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""
        self.existing_path: str = ""

    def tearDown(self) -> None:
        for path in [self.input_path, self.output_path, self.existing_path]:
            if path and os.path.exists(path):
                os.unlink(path)

    def _run(
        self,
        rows: list[dict[str, str]],
        existing_rows: list[dict[str, str]] | None = None,
    ) -> dict:
        self.input_path = _write_csv(rows, list(rows[0].keys()))
        with tempfile.NamedTemporaryFile(delete=False, suffix=".csv") as handle:
            self.output_path = handle.name
        if existing_rows is not None:
            self.existing_path = _write_csv(
                existing_rows, list(existing_rows[0].keys())
            )
        return run(
            self.input_path,
            self.output_path,
            existing_review_path=self.existing_path,
        )

    def _read_output(self) -> list[dict[str, str]]:
        with open(self.output_path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_mass_food_uses_per_100g_basis(self) -> None:
        self._run([
            _row(
                description="Rice",
                value="200",
                unit="g",
                calories="260",
                fat_g="1",
                carbs_g="56",
                protein_g="5",
            ),
            _row(
                description="Rice",
                value="150",
                unit="g",
                calories="195",
                fat_g="0.75",
                carbs_g="42",
                protein_g="3.75",
            ),
        ])
        out = self._read_output()
        assert len(out) == 1
        assert out[0]["serving_mode"] == "mass"
        assert out[0]["reference_basis"] == "per_100g"
        assert out[0]["reference_calories"] == "130"
        assert out[0]["current_serving_grams"] == "100"

    def test_volume_food_uses_per_100ml_basis(self) -> None:
        self._run([
            _row(
                description="Almond Milk",
                value="250",
                unit="ml",
                serving="250.0 ml",
                calories="50",
                fat_g="4",
                carbs_g="1",
                protein_g="2",
            ),
        ])
        out = self._read_output()
        assert out[0]["serving_mode"] == "volume"
        assert out[0]["reference_basis"] == "per_100ml"
        assert out[0]["reference_calories"] == "20"
        assert out[0]["current_serving_grams"] == ""

    def test_serving_unit_food_uses_per_serving_basis(self) -> None:
        self._run([
            _row(
                description="Boiled Egg",
                value="2",
                unit="serving",
                serving="2.0 eggs",
                calories="143",
                fat_g="9.5",
                carbs_g="0.72",
                protein_g="12.56",
            ),
        ])
        out = self._read_output()
        assert out[0]["serving_mode"] == "serving_unit"
        assert out[0]["reference_basis"] == "per_serving"
        assert out[0]["reference_calories"] == "71.5"
        assert out[0]["example_unit"] == "serving"

    def test_outputs_all_reference_columns_and_converts_daily_values(self) -> None:
        self._run([
            _row(
                description="Fortified Oats",
                value="50",
                unit="g",
                serving="50.0 g",
                calories="190",
                fat_g="5",
                carbs_g="33",
                protein_g="7",
                fiber_g="8",
                sugar_g="2",
                saturated_fat_g="1",
                trans_fat_g="0",
                monounsaturated_fat_g="1.5",
                polyunsaturated_fat_g="2",
                cholesterol_mg="0",
                sodium_mg="120",
                calcium_mg="260",
                potassium_mg="180",
                vitamin_d_pct_daily_value="10%",
                iron_pct_daily_value="25",
                vitamin_a_pct_daily_value="15.0",
                vitamin_c_pct_daily_value="8",
            ),
        ])
        out = self._read_output()
        reference_columns = set(out[0]).intersection(
            REQUIRED_REVIEW_REFERENCE_COLUMNS
        )
        assert set(REQUIRED_REVIEW_REFERENCE_COLUMNS) == reference_columns
        assert out[0]["reference_fiber_g"] == "16"
        assert out[0]["reference_sugar_g"] == "4"
        assert out[0]["reference_saturated_fat_g"] == "2"
        assert out[0]["reference_trans_fat_g"] == "0"
        assert out[0]["reference_monounsaturated_fat_g"] == "3"
        assert out[0]["reference_polyunsaturated_fat_g"] == "4"
        assert out[0]["reference_cholesterol_mg"] == "0"
        assert out[0]["reference_sodium_mg"] == "240"
        assert out[0]["reference_calcium_mg"] == "520"
        assert out[0]["reference_potassium_mg"] == "360"
        assert out[0]["reference_vitamin_d_ug"] == "4"
        assert out[0]["reference_iron_mg"] == "9"
        assert out[0]["reference_vitamin_a_ug"] == "270"
        assert out[0]["reference_vitamin_c_mg"] == "14.4"

    def test_scales_daily_value_conversion_for_volume_basis(self) -> None:
        self._run([
            _row(
                description="Fortified Juice",
                value="250",
                unit="ml",
                serving="250.0 ml",
                calories="100",
                fat_g="0",
                carbs_g="24",
                protein_g="0",
                vitamin_d_pct_daily_value="25%",
            ),
        ])
        out = self._read_output()
        assert out[0]["serving_mode"] == "volume"
        assert out[0]["reference_vitamin_d_ug"] == "2"

    def test_existing_review_values_are_preserved(self) -> None:
        existing = [{
            "description": "Boiled Egg",
            "row_count": "1",
            "serving_mode": "serving_unit",
            "reference_basis": "per_serving",
            "reference_calories": "71.5",
            "reference_protein_g": "6.3",
            "reference_carbs_g": "0.4",
            "reference_fat_g": "4.8",
            "example_value": "1",
            "example_unit": "serving",
            "example_serving": "1.0 egg",
            "current_serving_grams": "50",
            "corrected_serving_grams": "52",
            "confidence": "high",
            "notes": "reviewed",
        }]
        self._run([
            _row(
                description="Boiled Egg",
                value="1",
                unit="serving",
                serving="1.0 egg",
                calories="71.5",
                fat_g="4.8",
                carbs_g="0.4",
                protein_g="6.3",
            ),
        ], existing_rows=existing)
        out = self._read_output()
        assert out[0]["current_serving_grams"] == "50"
        assert out[0]["corrected_serving_grams"] == "52"
        assert out[0]["confidence"] == "high"
        assert out[0]["notes"] == "reviewed"


    def test_existing_review_is_preserved_despite_trailing_whitespace(self) -> None:
        existing = [{
            "description": "Chili Garlic Noodles",
            "row_count": "1",
            "serving_mode": "serving_unit",
            "reference_basis": "per_serving",
            "reference_calories": "961",
            "reference_protein_g": "27",
            "reference_carbs_g": "186.2",
            "reference_fat_g": "13.5",
            "example_value": "0.333",
            "example_unit": "serving",
            "example_serving": "0.333 package",
            "current_serving_grams": "",
            "corrected_serving_grams": "25",
            "confidence": "low",
            "notes": "one-third package dry-weight estimate",
        }]
        self._run([
            _row(
                description="Chili Garlic Noodles ",
                value="0.333",
                unit="serving",
                serving="0.333 package",
                calories="961",
                fat_g="13.5",
                carbs_g="186.2",
                protein_g="27",
            ),
        ], existing_rows=existing)
        out = self._read_output()
        assert out[0]["corrected_serving_grams"] == "25"
        assert out[0]["confidence"] == "low"
        assert out[0]["notes"] == "one-third package dry-weight estimate"


if __name__ == "__main__":
    unittest.main()
