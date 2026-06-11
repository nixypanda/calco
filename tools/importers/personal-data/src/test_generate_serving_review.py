"""Tests for Step 9: generate_serving_review."""

import csv
import os
import tempfile
import unittest

from steps.generate_serving_review import run


BASE = [
    "item_type", "date", "description", "value", "unit", "serving", "meal",
    "calories", "fat_g", "carbs_g", "protein_g",
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
        self.input_path = None
        self.output_path = None
        self.existing_path = None

    def tearDown(self) -> None:
        for path in [self.input_path, self.output_path, self.existing_path]:
            if path and os.path.exists(path):
                os.unlink(path)

    def _run(self, rows: list[dict[str, str]], existing_rows: list[dict[str, str]] | None = None) -> dict:
        self.input_path = _write_csv(rows, list(rows[0].keys()))
        self.output_path = tempfile.NamedTemporaryFile(delete=False, suffix=".csv").name
        if existing_rows is not None:
            self.existing_path = _write_csv(existing_rows, list(existing_rows[0].keys()))
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
            _row(description="Rice", value="200", unit="g", calories="260", fat_g="1", carbs_g="56", protein_g="5"),
            _row(description="Rice", value="150", unit="g", calories="195", fat_g="0.75", carbs_g="42", protein_g="3.75"),
        ])
        out = self._read_output()
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["serving_mode"], "mass")
        self.assertEqual(out[0]["reference_basis"], "per_100g")
        self.assertEqual(out[0]["reference_calories"], "130")
        self.assertEqual(out[0]["current_serving_grams"], "100")

    def test_volume_food_uses_per_100ml_basis(self) -> None:
        self._run([
            _row(description="Almond Milk", value="250", unit="ml", serving="250.0 ml", calories="50", fat_g="4", carbs_g="1", protein_g="2"),
        ])
        out = self._read_output()
        self.assertEqual(out[0]["serving_mode"], "volume")
        self.assertEqual(out[0]["reference_basis"], "per_100ml")
        self.assertEqual(out[0]["reference_calories"], "20")
        self.assertEqual(out[0]["current_serving_grams"], "")

    def test_serving_unit_food_uses_per_serving_basis(self) -> None:
        self._run([
            _row(description="Boiled Egg", value="2", unit="serving", serving="2.0 eggs", calories="143", fat_g="9.5", carbs_g="0.72", protein_g="12.56"),
        ])
        out = self._read_output()
        self.assertEqual(out[0]["serving_mode"], "serving_unit")
        self.assertEqual(out[0]["reference_basis"], "per_serving")
        self.assertEqual(out[0]["reference_calories"], "71.5")
        self.assertEqual(out[0]["example_unit"], "serving")

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
            _row(description="Boiled Egg", value="1", unit="serving", serving="1.0 egg", calories="71.5", fat_g="4.8", carbs_g="0.4", protein_g="6.3"),
        ], existing_rows=existing)
        out = self._read_output()
        self.assertEqual(out[0]["current_serving_grams"], "50")
        self.assertEqual(out[0]["corrected_serving_grams"], "52")
        self.assertEqual(out[0]["confidence"], "high")
        self.assertEqual(out[0]["notes"], "reviewed")


if __name__ == "__main__":
    unittest.main()
