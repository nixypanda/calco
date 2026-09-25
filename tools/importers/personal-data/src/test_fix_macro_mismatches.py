"""Tests for Step 5: fix_macro_mismatches."""

import csv
import os
import tempfile
import unittest

from steps.fix_macro_mismatches import run

EXPECTED_CANONICAL_FIXES = 2
CALORIE_TOLERANCE_SMALL = 0.5
CALORIE_TOLERANCE_MEDIUM = 2
CALORIE_TOLERANCE_LARGE = 5


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
    "macro_mismatch",
]


def _row(**overrides: str) -> dict[str, str]:
    r: dict[str, str] = dict.fromkeys(BASE, "")
    r.update({
        "item_type": "Foods",
        "date": "2024-01-01",
        "description": "Test food",
        "value": "100",
        "unit": "g",
        "serving": "100.0 g",
        "meal": "Lunch",
        "calories": "300",
        "fat_g": "10",
        "carbs_g": "30",
        "protein_g": "15",
        "macro_mismatch": "TRUE",
    })
    r.update(overrides)
    return r


class FixMacroMismatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for p in [self.input_path, self.output_path]:
            if p and os.path.exists(p):
                os.unlink(p)
        review = os.path.join(
            os.path.dirname(self.output_path or "/tmp"),
            "step-5-corrections.csv",
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
            "step-5-corrections.csv",
        )
        with open(review, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_proportional_scaling_preserves_ratios(self) -> None:
        result = self._run(
            [_row(calories="250", fat_g="10", carbs_g="20", protein_g="10")]
        )
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 250) <= 1
        assert result["total_fixed"] == 1
        assert result["proportional_scaling"] == 1

    def test_canonical_cucumber(self) -> None:
        result = self._run([_row(
            description="Cucumber",
            calories="22.5",
            fat_g="0.165",
            carbs_g="5.445",
            protein_g="0.975",
            value="150",
            unit="g",
        )])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 22.5) <= CALORIE_TOLERANCE_SMALL
        assert result["canonical"] == 1

    def test_sabji_template(self) -> None:
        result = self._run([_row(
            description="Sabji",
            calories="84",
            fat_g="0",
            carbs_g="6",
            protein_g="0",
            value="3",
            unit="cup",
        )])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 84) <= CALORIE_TOLERANCE_MEDIUM
        assert nf > 0
        assert np_ > 0
        assert result["template"] == 1

    def test_non_mismatch_rows_skipped(self) -> None:
        rows = [
            _row(description="Skip me", macro_mismatch="FALSE"),
        ]
        result = self._run(rows)
        assert result["total_fixed"] == 0

    def test_zero_calories_skipped(self) -> None:
        result = self._run([_row(calories="0")])
        assert result["total_fixed"] == 0

    def test_review_file_written(self) -> None:
        self._run([_row(
            description="Cucumber",
            calories="22.5",
            fat_g="0.165",
            carbs_g="5.445",
            protein_g="0.975",
            value="150",
            unit="g",
        )])
        review = self._read_review()
        assert len(review) == 1
        assert "Cucumber" in review[0]["food_name"]
        assert "canonical" in review[0]["source_type"]
        assert "count" in review[0]
        assert review[0]["count"] == "1"
        for col in ("fat_g", "carbs_g", "protein_g"):
            assert col not in review[0]

    def test_proportional_for_unknown_food(self) -> None:
        result = self._run([_row(
            description="Some Unknown Dish",
            calories="200",
            fat_g="8",
            carbs_g="20",
            protein_g="10",
        )])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 200) <= 1
        assert result["proportional_scaling"] == 1

    def test_amul_shake_canonical(self) -> None:
        result = self._run([_row(
            description="Amul High Protein Blueberry Shake",
            calories="138",
            fat_g="1.5",
            carbs_g="19",
            protein_g="20",
            value="200",
            unit="ml",
        )])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 138) <= CALORIE_TOLERANCE_MEDIUM
        assert result["canonical"] == 1

    def test_steamed_rice_template(self) -> None:
        self._run([_row(
            description="Steamed",
            calories="195",
            fat_g="0",
            carbs_g="24",
            protein_g="1.5",
            value="150",
            unit="g",
        )])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        assert abs(total - 195) <= CALORIE_TOLERANCE_LARGE
        assert nf > 0

    def test_multiple_rows(self) -> None:
        rows = [
            _row(description="Cucumber", calories="22.5", fat_g="0.165",
                 carbs_g="5.445", protein_g="0.975", value="150", unit="g"),
            _row(description="Guava", calories="68", fat_g="1",
                 carbs_g="19", protein_g="2.6", value="100", unit="g"),
            _row(description="Sabji", calories="84", fat_g="0",
                 carbs_g="6", protein_g="0", value="3", unit="cup"),
        ]
        result = self._run(rows)
        assert result["total_fixed"] == len(rows)
        assert result["canonical"] == EXPECTED_CANONICAL_FIXES
        assert result["template"] == 1


if __name__ == "__main__":
    unittest.main()
