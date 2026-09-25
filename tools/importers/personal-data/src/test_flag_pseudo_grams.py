"""Tests for Step 3: flag_pseudo_grams."""

import csv
import os
import tempfile
import unittest

from steps.flag_pseudo_grams import run

EXPECTED_REVIEW_ROWS = 2
CAL_PER_100G_TOLERANCE = 0.005


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


BASE_FIELDS = [
    "item_type", "date", "description", "value", "unit", "serving",
    "meal", "calories", "fat_g", "carbs_g", "protein_g",
]


def _row(**overrides: str) -> dict[str, str]:
    r: dict[str, str] = dict.fromkeys(BASE_FIELDS, "")
    r.update({
        "item_type": "Foods",
        "date": "2024-01-01",
        "description": "Test food",
        "value": "200",
        "unit": "g",
        "serving": "1.0 g",
        "meal": "Lunch",
        "calories": "300",
    })
    r.update(overrides)
    return r


class FlagPseudoGramsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str = ""
        self.output_path: str = ""

    def tearDown(self) -> None:
        for p in [self.input_path, self.output_path]:
            if p:
                os.unlink(p)
        review = os.path.join(
            os.path.dirname(self.output_path or "/tmp"),
            "step-3-review-pseudo-grams.csv",
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
            "step-3-review-pseudo-grams.csv",
        )
        with open(review, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_flags_pseudo_gram(self) -> None:
        result = self._run([_row()])
        out = self._read_output()
        assert result["total_flagged"] == 1
        assert out[0]["is_pseudo_gram"] == "TRUE"

    def test_does_not_flag_real_grams(self) -> None:
        result = self._run([_row(serving="250.0 g")])
        out = self._read_output()
        assert result["total_flagged"] == 0
        assert out[0]["is_pseudo_gram"] == "FALSE"

    def test_does_not_flag_low_cal(self) -> None:
        result = self._run([_row(calories="15", value="1")])
        out = self._read_output()
        assert result["total_flagged"] == 0
        assert out[0]["is_pseudo_gram"] == "FALSE"

    def test_does_not_flag_non_g_unit(self) -> None:
        result = self._run([_row(unit="serving", serving="1.0 egg")])
        out = self._read_output()
        assert result["total_flagged"] == 0
        assert out[0]["is_pseudo_gram"] == "FALSE"

    def test_does_not_flag_non_food(self) -> None:
        result = self._run([_row(item_type="Measurement", calories="")])
        out = self._read_output()
        assert result["total_flagged"] == 0
        assert out[0]["is_pseudo_gram"] == "FALSE"

    def test_review_file_has_correct_rows(self) -> None:
        rows = [
            _row(description="Kali Dal Makhani", value="400", calories="544"),
            _row(description="White rice, cooked", value="250", calories="322.5"),
            _row(description="Cucumber", serving="150.0 g", value="1", calories="15"),
        ]
        self._run(rows)
        review = self._read_review()
        assert len(review) == EXPECTED_REVIEW_ROWS
        assert review[0]["description"] == "Kali Dal Makhani"
        assert review[1]["description"] == "White rice, cooked"

    def test_review_file_header(self) -> None:
        self._run([_row()])
        review = self._read_review()
        expected = {"description", "date", "meal", "value_g",
                    "calories", "cal_per_100g", "outside_range"}
        assert set(review[0].keys()) == expected

    def test_cal_per_100g_correct(self) -> None:
        self._run([_row(description="Nutella", value="20", calories="119.8")])
        review = self._read_review()
        assert review[0]["value_g"] == "20"
        assert review[0]["calories"] == "119.8"
        assert abs(float(review[0]["cal_per_100g"]) - 599.0) < CAL_PER_100G_TOLERANCE

    def test_outside_range_flag(self) -> None:
        self._run([_row(description="Nutella", value="20", calories="119.8")])
        review = self._read_review()
        assert review[0]["outside_range"] == "YES"

    def test_inside_range_flag(self) -> None:
        self._run([_row(description="Kali Dal Makhani", value="400", calories="544")])
        review = self._read_review()
        assert review[0]["outside_range"] == "NO"

    def test_empty_serving_not_flagged(self) -> None:
        result = self._run([_row(serving="")])
        assert result["total_flagged"] == 0

    def test_zero_value_not_crashing(self) -> None:
        result = self._run([_row(value="0")])
        out = self._read_output()
        assert result["total_flagged"] == 1
        assert out[0]["is_pseudo_gram"] == "TRUE"


if __name__ == "__main__":
    unittest.main()
