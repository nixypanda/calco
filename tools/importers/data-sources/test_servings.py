import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from calco_import.fetch.indb import _build_indb_serving_row
from calco_import.fetch.off import OffIndices, _build_off_serving_row
from calco_import.fetch.usda import _build_serving_rows
from calco_import.util import parse_amount


class ServingFetcherTests(unittest.TestCase):
    def test_usda_normalizes_portion_weight_by_amount_and_deduplicates_unit(self) -> None:
        food = {
            "foodPortions": [
                {
                    "gramWeight": 42,
                    "amount": 3,
                    "measureUnit": {"abbreviation": "piece"},
                    "portionDescription": "three pieces",
                },
                {
                    "gramWeight": 56,
                    "amount": 4,
                    "measureUnit": {"abbreviation": "piece"},
                    "portionDescription": "four pieces",
                },
                {
                    "gramWeight": 240,
                    "amount": 1,
                    "measureUnit": {"abbreviation": "cup"},
                },
                {
                    "gramWeight": 10,
                    "amount": 0,
                    "measureUnit": {"abbreviation": "invalid"},
                },
            ]
        }

        self.assertEqual(
            list(_build_serving_rows(food, "123")),
            [
                {
                    "type": "serving",
                    "source": "USDA",
                    "source_id": "123",
                    "unit": "piece",
                    "grams_per_unit": 14.0,
                },
                {
                    "type": "serving",
                    "source": "USDA",
                    "source_id": "123",
                    "unit": "cup",
                    "grams_per_unit": 240.0,
                },
            ],
        )

    def test_off_emits_grams_per_serving(self) -> None:
        indices = OffIndices(0, 1, 2, 3, 4, 5, 6)
        row = ["890123", "", "", "", "", "32.5", "32.5 g"]

        self.assertEqual(
            _build_off_serving_row(row, indices, "890123"),
            {
                "type": "serving",
                "source": "OFF",
                "source_id": "890123",
                "unit": "serving",
                "grams_per_unit": 32.5,
            },
        )

    def test_indb_emits_grams_per_serving(self) -> None:
        row = (200, 50)
        col_index = {"energy_kcal": 0, "unit_serving_energy_kcal": 1}

        self.assertEqual(
            _build_indb_serving_row(row, col_index, "indb-1"),
            {
                "type": "serving",
                "source": "INDB",
                "source_id": "indb-1",
                "unit": "serving",
                "grams_per_unit": 25.0,
            },
        )


class ParseAmountTests(unittest.TestCase):
    def test_non_finite_amount_is_rejected(self) -> None:
        self.assertIsNone(parse_amount("NaN"))


if __name__ == "__main__":
    unittest.main()
