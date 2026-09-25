"""Tests for Step 4: check_macro_calories."""

import csv
import os
import tempfile
import unittest

from steps.check_macro_calories import run

DIFF_PCT_TOLERANCE = 0.05


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


BASE = [
    "item_type", "date", "description", "value", "unit", "serving",
    "meal", "calories", "fat_g", "carbs_g", "protein_g",
]


def _row(**overrides: str) -> dict[str, str]:
    r: dict[str, str] = dict.fromkeys(BASE, "")
    r.update({
        "item_type": "Foods",
        "date": "2024-01-01",
        "description": "Test food",
        "value": "100",
        "unit": "g",
        "serving": "1.0 g",
        "meal": "Lunch",
        "calories": "300",
        "fat_g": "10",
        "carbs_g": "30",
        "protein_g": "15",
    })
    r.update(overrides)
    return r


class MacroCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for p in [self.input_path, self.output_path]:
            if p:
                os.unlink(p)
        review = os.path.join(
            os.path.dirname(self.output_path or "/tmp"),
            "step-4-review-macro-mismatch.csv",
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
            "step-4-review-macro-mismatch.csv",
        )
        with open(review, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_matches_within_threshold(self) -> None:
        result = self._run([_row()])
        out = self._read_output()
        assert result["mismatches"] == 0
        assert out[0]["macro_mismatch"] == "FALSE"

    def test_large_mismatch_flagged(self) -> None:
        row = _row(description="Chole Palak", calories="123",
                    fat_g="20", carbs_g="24.4", protein_g="5.8")
        result = self._run([row])
        out = self._read_output()
        review = self._read_review()
        assert result["mismatches"] == 1
        assert out[0]["macro_mismatch"] == "TRUE"
        assert len(review) == 1
        assert "Chole Palak" in review[0]["description"]

    def test_skipped_rows_marked_skip(self) -> None:
        row = _row(calories="", fat_g="10", carbs_g="20", protein_g="5")
        result = self._run([row])
        out = self._read_output()
        assert result["checked"] == 0
        assert out[0]["macro_mismatch"] == "SKIP"

    def test_skipped_partial_macros(self) -> None:
        row = _row(calories="100", fat_g="10", carbs_g="", protein_g="5")
        result = self._run([row])
        assert result["checked"] == 0
        assert result["total_food_rows"] == 1

    def test_non_food_skipped(self) -> None:
        row = _row(
            item_type="Measurement",
            calories="",
            fat_g="",
            carbs_g="",
            protein_g="",
        )
        result = self._run([row])
        out = self._read_output()
        assert result["checked"] == 0
        assert out[0]["macro_mismatch"] == "FALSE"

    def test_zero_calories_not_flagged(self) -> None:
        row = _row(calories="0", fat_g="0", carbs_g="0", protein_g="0")
        result = self._run([row])
        out = self._read_output()
        assert result["mismatches"] == 0
        assert out[0]["macro_mismatch"] == "FALSE"

    def test_review_file_header(self) -> None:
        self._run([_row(description="Chole Palak", calories="123",
                         fat_g="20", carbs_g="24.4", protein_g="5.8")])
        review = self._read_review()
        expected = {"description", "date", "meal", "calories",
                    "macro_cal", "diff_pct", "fat_g", "carbs_g", "protein_g"}
        assert set(review[0].keys()) == expected

    def test_diff_pct_in_review(self) -> None:
        self._run([_row(description="Chole Palak", calories="123",
                         fat_g="20", carbs_g="24.4", protein_g="5.8")])
        review = self._read_review()
        diff = float(review[0]["diff_pct"])
        assert abs(diff - 144.6) < DIFF_PCT_TOLERANCE


if __name__ == "__main__":
    unittest.main()
