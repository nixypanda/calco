import csv
import os
import tempfile
import unittest

import mfp_import

HEADER = [
    "",
    "username",
    "user_id",
    "email",
    "country_code",
    "ip_address",
    "height_in_inches",
    "sex",
    "dob",
    "zipcode",
    "account_deleted",
    "current_premium_subscriber",
    "current_trial",
    "item_type",
    "date",
    "description",
    "value",
    "unit",
    "calories",
    "fat_g",
    "saturated_fat_g",
    "trans_fat_g",
    "polyunsaturated_fat_g",
    "monounsaturated_fat_g",
    "cholesterol_mg",
    "sodium_mg",
    "carbs_g",
    "fiber_g",
    "sugar_g",
    "added_sugar_g",
    "sugar_alcohols_g",
    "protein_g",
    "vitamin_d_pct_daily_value",
    "calcium_mg",
    "iron_pct_daily_value",
    "potassium_mg",
    "vitamin_a_pct_daily_value",
    "vitamin_c_pct_daily_value",
]


def row(**overrides: str) -> list[str]:
    values = dict.fromkeys(HEADER, "")
    values.update(
        {
            "item_type": "Foods",
            "date": "2026-06-01",
            "description": "Roti",
            "value": "2",
            "unit": "piese",
            "calories": "160",
            "fat_g": "4",
            "carbs_g": "26",
            "protein_g": "4",
        }
    )
    values.update(overrides)
    return [values[key] for key in HEADER]


class MfpImportTests(unittest.TestCase):
    def write_csv(self, rows: list[list[str]]) -> str:
        with tempfile.NamedTemporaryFile("w", newline="", delete=False) as handle:
            writer = csv.writer(handle)
            writer.writerow(["test export"])
            writer.writerow(HEADER)
            writer.writerows(rows)
            return handle.name

    def test_load_mfp_food_rows_skips_non_food_rows(self) -> None:
        path = self.write_csv(
            [
                row(description="Roti"),
                row(item_type="Measurement", description="weight"),
            ]
        )
        self.addCleanup(os.unlink, path)

        rows, item_types = mfp_import.load_mfp_food_rows(path)

        assert len(rows) == 1
        assert item_types["Foods"] == 1
        assert item_types["Measurement"] == 1
        assert rows[0].normalized_unit == "piece"

    def test_group_foods_groups_by_normalized_description(self) -> None:
        path = self.write_csv(
            [
                row(description="White rice, cooked", value="150", unit="g"),
                row(description=" white   rice, cooked ", value="100", unit="grams"),
            ]
        )
        self.addCleanup(os.unlink, path)

        rows, _ = mfp_import.load_mfp_food_rows(path)
        grouped = mfp_import.group_foods(rows)

        assert len(grouped) == 1
        only_group = next(iter(grouped.values()))
        assert {food.normalized_unit for food in only_group} == {"g"}

    def test_review_flags_mark_mixed_units_manual(self) -> None:
        path = self.write_csv(
            [
                row(description="Rajma", value="200", unit="gram(s)"),
                row(description="Rajma", value="0.5", unit="cup"),
            ]
        )
        self.addCleanup(os.unlink, path)

        rows, _ = mfp_import.load_mfp_food_rows(path)
        mode = mfp_import.suggested_serving_mode(rows)
        approved, notes = mfp_import.review_flags(rows, mode)

        assert mode == "manual"
        assert not approved
        assert "mixed" in notes

    def test_review_flags_mark_suspicious_mass_rows(self) -> None:
        path = self.write_csv(
            [
                row(description="Curd", value="1", unit="gm", calories="62"),
            ]
        )
        self.addCleanup(os.unlink, path)

        rows, _ = mfp_import.load_mfp_food_rows(path)
        mode = mfp_import.suggested_serving_mode(rows)
        approved, notes = mfp_import.review_flags(rows, mode)

        assert mode == "mass"
        assert not approved
        assert "suspicious" in notes

    def test_mass_create_payload_can_include_reviewed_serving_alias(self) -> None:
        source = mfp_import.MfpFoodRow(
            row_number=3,
            date="2026-06-01",
            description="Rajma",
            normalized_description="rajma",
            value=mfp_import.Decimal("200"),
            unit="g",
            normalized_unit="g",
            nutrients={"ENERGY_KCAL": mfp_import.Decimal("240")},
        )
        review = mfp_import.ReviewRow(
            food_key="mfp:test",
            description="Rajma",
            normalized_description="rajma",
            action="create",
            approved=True,
            matched_product_id="",
            canonical_name="Rajma",
            serving_mode="mass",
            serving_unit="cup",
            serving_grams=mfp_import.Decimal("200"),
            notes="",
        )

        payload = mfp_import.create_food_payload(review, source)

        assert payload["default_unit"] == "g"
        assert payload["servings"][0]["unit"] == "cup"
        assert payload["servings"][0]["grams"] == "200"

    def test_serving_unit_payload_uses_reviewed_grams_for_nutrients(self) -> None:
        source = mfp_import.MfpFoodRow(
            row_number=3,
            date="2026-06-01",
            description="Curd",
            normalized_description="curd",
            value=mfp_import.Decimal("1"),
            unit="g",
            normalized_unit="g",
            nutrients={
                "ENERGY_KCAL": mfp_import.Decimal("62"),
                "PROTEIN_G": mfp_import.Decimal("4.1"),
            },
        )
        review = mfp_import.ReviewRow(
            food_key="mfp:test",
            description="Curd",
            normalized_description="curd",
            action="create",
            approved=True,
            matched_product_id="",
            canonical_name="Curd",
            serving_mode="serving_unit",
            serving_unit="g",
            serving_grams=mfp_import.Decimal("100"),
            notes="",
        )

        payload = mfp_import.create_food_payload(review, source)
        nutrients = {
            item["code"]: item["amount_per_100g"] for item in payload["nutrients"]
        }

        assert payload["serving_size_g"] == "100"
        assert nutrients["ENERGY_KCAL"] == "62"
        assert nutrients["PROTEIN_G"] == "4.1"


if __name__ == "__main__":
    unittest.main()
