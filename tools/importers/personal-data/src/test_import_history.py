"""Tests for historical food-log import helpers."""

from __future__ import annotations

import sys
import unittest
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from history_import import (
    ReviewRow,
    build_log_payload,
    extract_import_fingerprint,
    fingerprint_for_food_row,
    grams_for_food_row,
    normalize_meal_slot,
)


def _food_row(**overrides: str) -> dict[str, str]:
    row = {
        "date": "2024-03-18",
        "meal": "Lunch",
        "description": "Egg, boiled",
        "value": "2",
        "unit": "serving",
        "serving": "1.0 egg",
        "calories": "143",
        "protein_g": "12.56",
        "carbs_g": "0.72",
        "fat_g": "9.51",
    }
    row.update(overrides)
    return row


class ImportHistoryTests(unittest.TestCase):
    def test_normalizes_snacks_and_supplements_to_snack(self) -> None:
        self.assertEqual(normalize_meal_slot("Snacks"), "snack")
        self.assertEqual(normalize_meal_slot("Supplements"), "snack")

    def test_computes_grams_for_mass_rows_directly(self) -> None:
        review = ReviewRow(
            description="Rice",
            final_food_id="food-1",
            example_serving_amount=Decimal("100"),
            serving_grams=Decimal("100"),
            ready_for_log_import=True,
        )
        grams = grams_for_food_row(
            _food_row(description="Rice", value="150", unit="g", serving="100.0 g"),
            review,
        )
        self.assertEqual(grams, Decimal("150"))

    def test_computes_grams_for_serving_unit_rows(self) -> None:
        review = ReviewRow(
            description="Egg, boiled",
            final_food_id="food-1",
            example_serving_amount=Decimal("1"),
            serving_grams=Decimal("50"),
            ready_for_log_import=True,
        )
        grams = grams_for_food_row(_food_row(), review)
        self.assertEqual(grams, Decimal("100"))

    def test_computes_grams_for_volume_rows(self) -> None:
        review = ReviewRow(
            description="Cappuccino",
            final_food_id="food-1",
            example_serving_amount=Decimal("150"),
            serving_grams=Decimal("150"),
            ready_for_log_import=True,
        )
        grams = grams_for_food_row(
            _food_row(
                description="Cappuccino",
                value="300",
                unit="ml",
                serving="150.0 ml",
            ),
            review,
        )
        self.assertEqual(grams, Decimal("300"))

    def test_builds_gram_based_log_payload(self) -> None:
        review = ReviewRow(
            description="Egg, boiled",
            final_food_id="1e2fb787-cf24-4f05-ab1b-a8a22e40ec53",
            example_serving_amount=Decimal("1"),
            serving_grams=Decimal("50"),
            ready_for_log_import=True,
        )
        payload = build_log_payload(
            _food_row(),
            review,
            device_timezone="Asia/Kolkata",
        )
        self.assertEqual(payload["meal_slot"], "lunch")
        self.assertEqual(payload["item"]["id"], review.final_food_id)
        self.assertEqual(payload["quantity"], {"amount": 100, "unit": "g"})
        self.assertIn("mfp_import_fingerprint=", payload["notes"])

    def test_fingerprint_is_stable_and_extractable(self) -> None:
        row = _food_row()
        first = fingerprint_for_food_row(row)
        second = fingerprint_for_food_row(dict(row))
        self.assertEqual(first, second)
        extracted = extract_import_fingerprint(
            f"imported_from=myfitnesspal mfp_import_fingerprint={first}"
        )
        self.assertEqual(extracted, first)


if __name__ == "__main__":
    unittest.main()
