"""Tests for Step 2: scale_values."""

import csv
import os
import tempfile
import unittest

from steps.scale_values import run


def _write_csv(
    rows: list[dict],
    fieldnames: list[str] | None = None,
    title: str = "test export",
) -> str:
    if fieldnames is None:
        fieldnames = list(rows[0].keys())
    with tempfile.NamedTemporaryFile("w", newline="", delete=False, suffix=".csv") as f:
        f.write(title + "," * (len(fieldnames) - 1) + "\n")
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
        return f.name


class ScaleValuesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for p in [self.input_path, self.output_path]:
            if p:
                os.unlink(p)

    def _run(self, rows: list[dict]) -> dict:
        fieldnames = list(rows[0].keys())
        self.input_path = _write_csv(rows, fieldnames)
        with tempfile.NamedTemporaryFile(delete=False, suffix=".csv") as handle:
            self.output_path = handle.name
        return run(self.input_path, self.output_path)

    def _read_output(self) -> list[dict]:
        with open(self.output_path, newline="", encoding="utf-8") as f:
            f.readline()
            return list(csv.DictReader(f))

    def test_scales_by_serving_number(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Matar Mushroom",
            "value": "1.6667",
            "unit": "g",
            "serving": "250.0 g",
            "calories": "281",
        })

        result = self._run(rows)
        out = self._read_output()

        assert result["rows_scaled"] == 1
        assert out[0]["value"] == "416.675"

    def test_pseudo_gram_value_unchanged(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Kali Dal Makhani",
            "value": "400",
            "unit": "g",
            "serving": "1.0 g",
            "calories": "544",
        })

        self._run(rows)
        out = self._read_output()

        assert out[0]["value"] == "400"

    def test_egg_serving(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Eggs, boiled",
            "value": "2",
            "unit": "serving",
            "serving": "1.0 egg",
            "calories": "143",
        })

        result = self._run(rows)
        out = self._read_output()

        assert result["rows_scaled"] == 1
        assert out[0]["value"] == "2"

    def test_empty_serving_skipped(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Some food",
            "value": "100",
            "unit": "g",
            "serving": "",
            "calories": "100",
        })

        result = self._run(rows)

        assert result["rows_scaled"] == 0
        assert result["skipped_empty_serving"] == 1

    def test_zero_serving_skipped(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Some food",
            "value": "100",
            "unit": "g",
            "serving": "0.0 g",
            "calories": "0",
        })

        result = self._run(rows)

        assert result["rows_scaled"] == 0
        assert result["skipped_zero_serving"] == 1

    def test_non_food_skipped(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Measurement",
            "date": "2024-01-01",
            "description": "weight",
            "value": "70",
            "unit": "kg",
            "serving": "",
            "calories": "",
        })

        result = self._run(rows)

        assert result["rows_scaled"] == 0
        assert result["skipped_empty_serving"] == 0

    def test_sample_values_captured(self) -> None:
        rows = [
            dict.fromkeys(
                ["item_type", "date", "description", "value", "unit", "serving",
                 "meal", "calories", "fat_g", "carbs_g", "protein_g"], ""
            )
        ]
        rows[0].update({
            "item_type": "Foods",
            "date": "2024-01-01",
            "description": "Matar Mushroom",
            "value": "2",
            "unit": "g",
            "serving": "250.0 g",
            "calories": "281",
        })

        result = self._run(rows)

        assert result["sample_before"] == "2"
        assert result["sample_after"] == "500"


if __name__ == "__main__":
    unittest.main()
