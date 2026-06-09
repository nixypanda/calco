"""Tests for Step 1: normalize_units."""

import csv
import os
import tempfile
import unittest
from steps.normalize_units import normalize, run


def _write_csv(rows: list[dict], fieldnames: list[str] | None = None) -> str:
    if fieldnames is None:
        fieldnames = list(rows[0].keys())
    with tempfile.NamedTemporaryFile("w", newline="", delete=False, suffix=".csv") as f:
        f.write("test export," * (len(fieldnames) - 1) + "test export\n")
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
        return f.name


class NormalizeUnitTests(unittest.TestCase):
    def test_g_variants(self) -> None:
        for variant in ["g", "gm", "gram", "grams", "gram(s)", "G", "Gm",
                        "Gram", "Grams", "gms", "gramme"]:
            canon, scaled = normalize(variant, "100")
            self.assertEqual(canon, "g", f"{variant!r} should map to g")
            self.assertIsNone(scaled)

    def test_kg_converts_to_g_and_scales_value(self) -> None:
        canon, scaled = normalize("kg(s)", "0.25")
        self.assertEqual(canon, "g")
        self.assertEqual(scaled, "250")

    def test_kg_ignores_non_kg_units(self) -> None:
        canon, scaled = normalize("g", "0.25")
        self.assertEqual(canon, "g")
        self.assertIsNone(scaled)

    def test_ml_variants(self) -> None:
        for variant in ["ml", "mL"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "ml", f"{variant!r} should map to ml")
            self.assertIsNone(scaled)

    def test_cup_variants(self) -> None:
        cases = [
            ("cup", "cup"),
            ("Cup", "cup"),
            ("Cups", "cup"),
            ("cup cooked", "cup"),
        ]
        for variant, expected in cases:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, expected, f"{variant!r} should map to {expected!r}")
            self.assertIsNone(scaled)

    def test_cup_strips_comma_annotations(self) -> None:
        for variant in ["cup, pieces", "cup, popped"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "cup", f"{variant!r} should map to cup")
            self.assertIsNone(scaled)

    def test_cup_strips_parenthetical(self) -> None:
        canon, scaled = normalize("cup (250 gm)", "1")
        self.assertEqual(canon, "cup")
        self.assertIsNone(scaled)

    def test_cup_or_100g(self) -> None:
        canon, scaled = normalize("cup or 100g", "1")
        self.assertEqual(canon, "cup")
        self.assertIsNone(scaled)

    def test_bowl_variants(self) -> None:
        cases = [
            ("bowl", "bowl"),
            ("Bowl", "bowl"),
            ("household bowl", "bowl"),
            ("plate", "bowl"),
        ]
        for variant, expected in cases:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, expected, f"{variant!r} should map to {expected!r}")

    def test_katori_maps_to_cup(self) -> None:
        canon, scaled = normalize("katori", "1")
        self.assertEqual(canon, "cup")

    def test_tbsp_variants(self) -> None:
        for variant in ["tbsp", "tbs", "tablespoon"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "tbsp", f"{variant!r} should map to tbsp")
            self.assertIsNone(scaled)

    def test_ounce_variants(self) -> None:
        for variant in ["ounce", "oz"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "oz", f"{variant!r} should map to oz")
            self.assertIsNone(scaled)

    def test_egg_variants_map_to_serving(self) -> None:
        for variant in ["egg", "eggs", "Egg White", "egg whites"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_count_variants_map_to_serving(self) -> None:
        for variant in ["piece", "piese", "pcs", "pc", "pieces"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_other_count_units_map_to_serving(self) -> None:
        for variant in ["scoop", "slice", "slices", "bar", "large",
                        "medium", "serving", "package"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_medium_strips_parenthetical(self) -> None:
        canon, scaled = normalize('medium (7" to 7-7/8" long)', "1")
        self.assertEqual(canon, "serving")

    def test_sandwich_strips_parenthetical(self) -> None:
        canon, scaled = normalize("sandwich (200g)", "1")
        self.assertEqual(canon, "serving")

    def test_paratha_strips_parenthetical(self) -> None:
        canon, scaled = normalize("paratha (about 55g)", "1")
        self.assertEqual(canon, "serving")

    def test_empty_and_artifact_units(self) -> None:
        for variant in ["", '"', "'", "1"]:
            canon, scaled = normalize(variant, "100")
            self.assertEqual(canon, "", f"{variant!r} should map to empty")
            self.assertIsNone(scaled)

    def test_food_units_map_to_serving(self) -> None:
        for variant in ["wrap", "pastry", "pie", "can", "bottle",
                        "waffle", "Burrito", "omelette",
                        "pita with hummus", "bhatura with chole",
                        "Dose 0,33l"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_ingredient_units_map_to_serving(self) -> None:
        for variant in ["potato", "karela", "sausage", "wing"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_supplement_units_map_to_serving(self) -> None:
        for variant in ["Tablet", "capsule"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_misc_units_map_to_serving(self) -> None:
        for variant in ["pint", "idli", "ración", "meal", "finger bar",
                        "Roti", "unit", "100 calorie package"]:
            canon, scaled = normalize(variant, "1")
            self.assertEqual(canon, "serving", f"{variant!r} should map to serving")

    def test_unknown_unit_defaults_to_serving(self) -> None:
        canon, scaled = normalize("unknown_unit_xyz", "1")
        self.assertEqual(canon, "serving")
        self.assertIsNone(scaled)


class NormalizeRunIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.input_path = None
        self.output_path = None

    def tearDown(self):
        for p in [self.input_path, self.output_path]:
            if p:
                os.unlink(p)

    def test_run_modifies_units(self) -> None:
        rows = [
            dict.fromkeys(["item_type", "description", "value", "unit",
                          "date", "meal", "serving",
                          "calories", "fat_g", "carbs_g", "protein_g"], ""),
        ]
        rows[0].update({
            "item_type": "Foods",
            "description": "Roti",
            "value": "2",
            "unit": "piese",
            "date": "2024-01-01",
            "calories": "160",
        })

        fieldnames = list(rows[0].keys())
        self.input_path = _write_csv(rows, fieldnames)
        self.output_path = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv"
        ).name

        result = run(self.input_path, self.output_path)

        self.assertEqual(result["rows_modified"], 1)
        self.assertEqual(result["kg_to_gram_conversions"], 0)

        with open(self.output_path, newline="", encoding="utf-8") as f:
            f.readline()
            reader = csv.DictReader(f)
            out_rows = list(reader)
        self.assertEqual(out_rows[0]["unit"], "serving")

    def test_run_skips_non_foods(self) -> None:
        rows = [
            dict.fromkeys(["item_type", "description", "value", "unit",
                          "date", "meal", "serving",
                          "calories", "fat_g", "carbs_g", "protein_g"], ""),
            dict.fromkeys(["item_type", "description", "value", "unit",
                          "date", "meal", "serving",
                          "calories", "fat_g", "carbs_g", "protein_g"], ""),
        ]
        rows[0].update({
            "item_type": "Foods",
            "description": "Roti",
            "value": "2",
            "unit": "piese",
            "calories": "160",
            "date": "2024-01-01",
        })
        rows[1].update({
            "item_type": "Measurement",
            "description": "weight",
            "value": "70",
            "unit": "kg",
            "date": "2024-01-01",
        })

        fieldnames = list(rows[0].keys())
        self.input_path = _write_csv(rows, fieldnames)
        self.output_path = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv"
        ).name

        result = run(self.input_path, self.output_path)

        self.assertEqual(result["rows_modified"], 1)
        self.assertEqual(result["kg_to_gram_conversions"], 0)

    def test_run_scales_kg_values(self) -> None:
        rows = [
            dict.fromkeys(["item_type", "description", "value", "unit",
                          "date", "meal", "serving",
                          "calories", "fat_g", "carbs_g", "protein_g"], ""),
        ]
        rows[0].update({
            "item_type": "Foods",
            "description": "Brest",
            "value": "0.25",
            "unit": "kg(s)",
            "date": "2024-01-01",
            "calories": "200",
        })

        fieldnames = list(rows[0].keys())
        self.input_path = _write_csv(rows, fieldnames)
        self.output_path = tempfile.NamedTemporaryFile(
            delete=False, suffix=".csv"
        ).name

        result = run(self.input_path, self.output_path)

        self.assertEqual(result["rows_modified"], 1)
        self.assertEqual(result["kg_to_gram_conversions"], 1)

        with open(self.output_path, newline="", encoding="utf-8") as f:
            f.readline()
            reader = csv.DictReader(f)
            out_rows = list(reader)
        self.assertEqual(out_rows[0]["unit"], "g")
        self.assertEqual(out_rows[0]["value"], "250")


if __name__ == "__main__":
    unittest.main()
