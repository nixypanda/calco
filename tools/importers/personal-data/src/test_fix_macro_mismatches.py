"""Tests for Step 5: fix_macro_mismatches."""

import csv
import os
import tempfile
import unittest

from steps.fix_macro_mismatches import run


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


def _row(**overrides) -> dict:
    r = dict.fromkeys(BASE, "")
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
    def setUp(self):
        self.input_path = None
        self.output_path = None

    def tearDown(self):
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
        self.output_path = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv"
        ).name
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
        result = self._run([_row(calories="250", fat_g="10", carbs_g="20", protein_g="10")])
        out = self._read_output()
        nf = float(out[0]["fat_g"])
        nc = float(out[0]["carbs_g"])
        np_ = float(out[0]["protein_g"])
        total = nf * 9 + nc * 4 + np_ * 4
        self.assertAlmostEqual(total, 250, delta=1)
        self.assertEqual(result["total_fixed"], 1)
        self.assertEqual(result["proportional_scaling"], 1)

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
        self.assertAlmostEqual(total, 22.5, delta=0.5)
        self.assertEqual(result["canonical"], 1)

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
        self.assertAlmostEqual(total, 84, delta=2)
        self.assertGreater(nf, 0)
        self.assertGreater(np_, 0)
        self.assertEqual(result["template"], 1)

    def test_non_mismatch_rows_skipped(self) -> None:
        rows = [
            _row(description="Skip me", macro_mismatch="FALSE"),
        ]
        result = self._run(rows)
        self.assertEqual(result["total_fixed"], 0)

    def test_zero_calories_skipped(self) -> None:
        result = self._run([_row(calories="0")])
        self.assertEqual(result["total_fixed"], 0)

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
        self.assertEqual(len(review), 1)
        self.assertIn("Cucumber", review[0]["food_name"])
        self.assertIn("canonical", review[0]["source_type"])
        self.assertIn("count", review[0])
        self.assertEqual(review[0]["count"], "1")
        for col in ("fat_g", "carbs_g", "protein_g"):
            self.assertNotIn(col, review[0])

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
        self.assertAlmostEqual(total, 200, delta=1)
        self.assertEqual(result["proportional_scaling"], 1)

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
        self.assertAlmostEqual(total, 138, delta=2)
        self.assertEqual(result["canonical"], 1)

    def test_steamed_rice_template(self) -> None:
        result = self._run([_row(
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
        self.assertAlmostEqual(total, 195, delta=5)
        self.assertGreater(nf, 0)

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
        self.assertEqual(result["total_fixed"], 3)
        self.assertEqual(result["canonical"], 2)
        self.assertEqual(result["template"], 1)


if __name__ == "__main__":
    unittest.main()
