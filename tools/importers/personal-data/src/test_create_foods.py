"""Tests for create_foods helper behavior."""

from __future__ import annotations

import unittest

from create_foods import _custom_payload, _stage_import_rows

EXPECTED_GENERATED_NUTRIENTS = 5
EXPECTED_GRAMS_PER_PIECE = 14.0
EXPECTED_NUTRIENT_CODES = [
    "ENERGY_KCAL",
    "PROTEIN_G",
    "FAT_G",
    "SODIUM_MG",
    "VITAMIN_D_UG",
]


def _record(**overrides: object) -> dict[str, object]:
    record: dict[str, object] = {
        "name": "Whey",
        "brand": "MyFitnessPal",
        "categories": ["mfp-import"],
        "default_quantity": 1,
        "default_unit": "serving",
        "nutrients": [
            {
                "code": "ENERGY_KCAL",
                "amount_per_100g": 400,
                "source": "mfp",
                "confidence": "reviewed",
            },
            {
                "code": "PROTEIN_G",
                "amount_per_100g": 80,
                "source": "mfp",
                "confidence": "reviewed",
            },
            {
                "code": "FAT_G",
                "amount_per_100g": 3.3333,
                "source": "mfp",
                "confidence": "reviewed",
            },
            {
                "code": "SODIUM_MG",
                "amount_per_100g": 500,
                "source": "mfp",
                "confidence": "reviewed",
            },
            {
                "code": "VITAMIN_D_UG",
                "amount_per_100g": 6.6667,
                "source": "mfp",
                "confidence": "reviewed",
            },
        ],
        "servings": [
            {
                "unit": "serving",
                "grams_per_unit": 30,
            }
        ],
    }
    record.update(overrides)
    return record


class CreateFoodsHelperTests(unittest.TestCase):
    def test_custom_payload_backfills_only_missing_required_macros(self) -> None:
        payload = _custom_payload(_record())

        assert [
            nutrient["code"] for nutrient in payload["nutrients"]
        ] == [*EXPECTED_NUTRIENT_CODES, "CARBS_G"]
        carbs = payload["nutrients"][-1]
        assert carbs == {
            "code": "CARBS_G",
            "amount_per_100g": 0,
            "source": "mfp",
            "confidence": "reviewed",
        }

    def test_stage_import_rows_forwards_all_generated_nutrients(self) -> None:
        _foods, nutrients, _servings, source_ids = _stage_import_rows([_record()])

        assert len(nutrients) == EXPECTED_GENERATED_NUTRIENTS
        assert [
            row["nutrient_code"] for row in nutrients
        ] == EXPECTED_NUTRIENT_CODES
        assert list(source_ids) == ["Whey"]
        assert source_ids["Whey"].startswith("mfp-personal-data:")

    def test_stage_import_rows_forwards_simplified_servings(self) -> None:
        _foods, _nutrients, servings, _source_ids = _stage_import_rows([_record()])

        assert servings[0] == {
            "row_number": 1,
            "source": "USER",
            "source_id": servings[0]["source_id"],
            "unit": "serving",
            "grams_per_unit": 30,
        }

    def test_custom_payload_normalizes_legacy_serving_shape(self) -> None:
        payload = _custom_payload(
            _record(
                servings=[
                    {
                        "label": "three pieces",
                        "quantity": 3,
                        "unit": "piece",
                        "grams": 42,
                    }
                ]
            )
        )

        assert payload["servings"] == [{"unit": "piece", "grams_per_unit": 14.0}]

    def test_stage_import_rows_normalizes_legacy_serving_shape(self) -> None:
        _foods, _nutrients, servings, _source_ids = _stage_import_rows(
            [
                _record(
                    servings=[
                        {
                            "label": "three pieces",
                            "quantity": 3,
                            "unit": "piece",
                            "grams": 42,
                        }
                    ]
                )
            ]
        )

        assert servings[0]["unit"] == "piece"
        assert servings[0]["grams_per_unit"] == EXPECTED_GRAMS_PER_PIECE


if __name__ == "__main__":
    unittest.main()
