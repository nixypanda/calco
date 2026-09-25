"""Tests for Step 6: resolve_serving_modes."""

import csv
import os
import tempfile
import unittest

from steps.resolve_serving_modes import run

VALUE_TOLERANCE = 0.5
DENSITY_VALUE_TOLERANCE = 5


def _write_csv(rows: list[dict], fieldnames: list[str] | None = None) -> str:
    if fieldnames is None:
        fieldnames = list(rows[0].keys())
    with tempfile.NamedTemporaryFile("w", newline="", delete=False, suffix=".csv") as f:
        f.write("sherubthakur Data Access Request," * (len(fieldnames) - 1) + "\n")
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
        return f.name


BASE = [
    "item_type", "date", "description", "value", "unit", "serving",
    "meal", "calories", "fat_g", "carbs_g", "protein_g",
]


def _row(**overrides: str) -> dict:
    r = dict.fromkeys(BASE, "")
    r.update({
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
    r.update(overrides)
    return r


class ResolveServingModesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for p in [self.input_path, self.output_path]:
            if p and os.path.exists(p):
                os.unlink(p)
        review = os.path.join(
            os.path.dirname(self.output_path or "/tmp"),
            "step-6-review-serving-modes.csv",
        )
        if os.path.exists(review):
            os.unlink(review)

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

    def _read_review(self) -> list[dict]:
        review = os.path.join(
            os.path.dirname(self.output_path),
            "step-6-review-serving-modes.csv",
        )
        with open(review, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    # --- single-mode foods (no action) ---

    def test_single_mode_food_passes_through(self) -> None:
        rows = [
            _row(description="Rice", value="200", unit="g", calories="260"),
            _row(description="Rice", value="150", unit="g", calories="195"),
        ]
        result = self._run(rows)
        out = self._read_output()
        assert len(out) == len(rows)
        assert out[0]["unit"] == "g"
        assert result["total_multi_mode_foods"] == 0

    # --- volume-to-gram conversion ---

    def test_tbsp_to_gram_conversion(self) -> None:
        rows = [
            _row(description="Nutella", value="30", unit="g",
                 calories="162", serving="1.0 g"),
            _row(description="Nutella", value="2", unit="tbsp",
                 calories="200", serving="1.0 tbsp"),
        ]
        result = self._run(rows)
        out = self._read_output()
        tbsp_rows = [r for r in out if r["unit"] == "tbsp"]
        assert len(tbsp_rows) == 0
        g_rows = [r for r in out if r["unit"] == "g"]
        assert len(g_rows) == len(rows)
        # The tbsp entry should be converted: 2 x 15 = 30g
        assert abs(float(g_rows[1]["value"]) - 30) <= VALUE_TOLERANCE
        assert result["converted_to_grams"] == 1

    def test_cup_to_gram_conversion(self) -> None:
        rows = [
            _row(description="Rajma", value="250", unit="g",
                 calories="252", serving="1.0 gram(s)"),
            _row(description="Rajma", value="0.5", unit="cup",
                 calories="126", serving="1.0 cup"),
        ]
        result = self._run(rows)
        out = self._read_output()
        cup_rows = [r for r in out if r["unit"] == "cup"]
        assert len(cup_rows) == 0
        converted = [r for r in out if r["unit"] == "g"]
        assert len(converted) == len(rows)
        # 0.5 cup x 200 = 100g
        assert abs(float(converted[1]["value"]) - 100) <= VALUE_TOLERANCE
        assert result["converted_to_grams"] == 1

    # --- density inference ---

    def test_density_inference(self) -> None:
        rows = [
            _row(description="Mashed potatoes", value="30", unit="g",
                 calories="34.2", serving="1.0 g"),
            _row(description="Mashed potatoes", value="1", unit="serving",
                 calories="167.58", serving="1.0 potato"),
        ]
        result = self._run(rows)
        out = self._read_output()
        serving_rows = [r for r in out if r["unit"] == "serving"]
        g_rows = [
            r
            for r in out
            if r["description"] == "Mashed potatoes" and r["unit"] == "g"
        ]
        assert len(serving_rows) == 0
        # 167.58 cal at 114 cal/100g → 167.58/1.14 = 147g
        assert abs(float(g_rows[1]["value"]) - 147) <= DENSITY_VALUE_TOLERANCE
        assert result["converted_to_grams"] == 1

    def test_density_inference_no_gram_entries_skipped(self) -> None:
        rows = [
            _row(description="Odd Food", value="1", unit="serving",
                 calories="200", serving="1.0 bowl"),
            _row(description="Odd Food", value="2", unit="cup",
                 calories="400", serving="1.0 cup"),
        ]
        result = self._run(rows)
        out = self._read_output()
        # No gram entries exist → should not convert
        assert out[0]["unit"] == "serving"
        assert result["converted_to_grams"] == 0

    # --- Homemade relabel ---

    def test_homemade_omelette_relabelled(self) -> None:
        rows = [
            _row(description="Homemade", value="200", unit="g",
                 calories="154", serving="1.0 Gram"),
            _row(description="Homemade", value="1", unit="serving",
                 calories="184", serving="1.0 omelette"),
        ]
        result = self._run(rows)
        out = self._read_output()
        # The omelette entry should be relabelled
        relabelled = [r for r in out if r["description"] == "Sunny Side Up Egg"]
        homemade_g = [r for r in out if r["description"] == "Homemade"]
        assert len(relabelled) == 1
        assert len(homemade_g) == 1
        assert result["relabelled"] == 1

    def test_homemade_gram_entries_unchanged(self) -> None:
        rows = [
            _row(description="Homemade", value="200", unit="g",
                 calories="154", serving="1.0 Gram"),
            _row(description="Homemade", value="150", unit="g",
                 calories="115", serving="1.0 Gram"),
        ]
        result = self._run(rows)
        out = self._read_output()
        # Both are g → single mode, no action
        assert len([r for r in out if r["description"] == "Homemade"]) == len(rows)
        assert result["total_multi_mode_foods"] == 0

    # --- review file ---

    def test_review_file_written(self) -> None:
        rows = [
            _row(description="Nutella", value="30", unit="g",
                 calories="162", serving="1.0 g"),
            _row(description="Nutella", value="2", unit="tbsp",
                 calories="200", serving="1.0 tbsp"),
        ]
        self._run(rows)
        review = self._read_review()
        assert len(review) == 1
        assert review[0]["food_name"] == "Nutella"
        assert review[0]["resolution"] == "auto"
        assert "converted_entries" in review[0]

    def test_review_file_columns(self) -> None:
        rows = [
            _row(description="Rajma", value="250", unit="g",
                 calories="252", serving="1.0 gram(s)"),
            _row(description="Rajma", value="0.5", unit="cup",
                 calories="126", serving="1.0 cup"),
        ]
        self._run(rows)
        review = self._read_review()
        expected = {"food_name", "resolution", "observed_units",
                     "converted_entries", "notes"}
        assert set(review[0].keys()) == expected

    def test_non_food_skipped(self) -> None:
        rows = [
            _row(item_type="Exercise", description="Running",
                 value="30", unit="min"),
        ]
        result = self._run(rows)
        assert result["total_multi_mode_foods"] == 0

    def test_no_change_when_single_entry(self) -> None:
        rows = [
            _row(description="Single Food", value="100", unit="g", calories="300"),
        ]
        result = self._run(rows)
        out = self._read_output()
        assert len(out) == 1
        assert out[0]["unit"] == "g"
        assert result["total_multi_mode_foods"] == 0


if __name__ == "__main__":
    unittest.main()
