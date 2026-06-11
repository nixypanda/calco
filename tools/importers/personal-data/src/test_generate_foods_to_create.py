"""Tests for Step 13: generate_foods_to_create."""

from __future__ import annotations

import csv
import json
import os
import tempfile
import unittest

from steps.generate_foods_to_create import run

BREADED_SERVING_G = 30
DOUBLE_RECORD_COUNT = 2
ML_BASIS_GRAMS = 100

FIELDS = [
    "description",
    "row_count",
    "serving_mode",
    "reference_basis",
    "reference_calories",
    "reference_protein_g",
    "reference_carbs_g",
    "reference_fat_g",
    "example_value",
    "example_unit",
    "example_serving",
    "current_serving_grams",
    "corrected_serving_grams",
    "confidence",
    "notes",
    "matched_food_id",
    "matched_food_name",
    "match_confidence",
    "match_basis",
    "match_notes",
]


def _write_csv(rows: list[dict[str, str]]) -> str:
    with tempfile.NamedTemporaryFile(
        "w",
        newline="",
        delete=False,
        suffix=".csv",
        encoding="utf-8",
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
        return handle.name


def _temp_path(suffix: str) -> str:
    fd, path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    return path


def _row(**overrides: str) -> dict[str, str]:
    row = dict.fromkeys(FIELDS, "")
    row.update(
        {
            "description": "Whey",
            "row_count": "268",
            "serving_mode": "serving_unit",
            "reference_basis": "per_serving",
            "reference_calories": "120",
            "reference_protein_g": "24",
            "reference_carbs_g": "3",
            "reference_fat_g": "1",
            "example_value": "1",
            "example_unit": "serving",
            "example_serving": "1.0 scoop",
            "corrected_serving_grams": "30",
            "confidence": "high",
            "notes": "standard whey scoop",
        }
    )
    row.update(overrides)
    return row


class GenerateFoodsToCreateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str | None = None
        self.output_path: str | None = None

    def tearDown(self) -> None:
        for path in [self.input_path, self.output_path]:
            if path and os.path.exists(path):
                os.unlink(path)

    def _run(self, rows: list[dict[str, str]]) -> dict[str, int]:
        self.input_path = _write_csv(rows)
        self.output_path = _temp_path(".jsonl")
        return run(self.input_path, self.output_path)

    def _run_all_unmatched(self, rows: list[dict[str, str]]) -> dict[str, int]:
        self.input_path = _write_csv(rows)
        self.output_path = _temp_path(".jsonl")
        return run(self.input_path, self.output_path, selection="all-unmatched")

    def _read_jsonl(self) -> list[dict[str, object]]:
        with open(self.output_path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_generates_per_serving_payload_for_approved_raw_basic_row(self) -> None:
        result = self._run([_row()])
        records = self._read_jsonl()

        assert result["created"] == 1
        assert result["raw_basic"] == 1
        assert records[0]["name"] == "Whey"
        assert records[0]["serving_size_g"] == BREADED_SERVING_G
        assert records[0]["default_unit"] == "serving"
        assert records[0]["nutrients"] == [
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
                "code": "CARBS_G",
                "amount_per_100g": 10,
                "source": "mfp",
                "confidence": "reviewed",
            },
            {
                "code": "FAT_G",
                "amount_per_100g": 3.3333,
                "source": "mfp",
                "confidence": "reviewed",
            },
        ]
        assert records[0]["provenance"]["policy_bucket"] == "raw_basic"

    def test_normalizes_whitespace_for_approved_branded_rows(self) -> None:
        result = self._run(
            [
                _row(
                    description="Choco Pie ",
                    row_count="4",
                    reference_calories="125",
                    reference_protein_g="1",
                    reference_carbs_g="19",
                    reference_fat_g="5",
                    corrected_serving_grams="30",
                    notes="standard snack cake estimate",
                ),
                _row(
                    description="Bonn\u00a0multigrain\u00a0sub\u00a0bread",
                    serving_mode="mass",
                    reference_basis="per_100g",
                    row_count="1",
                    example_value="150",
                    example_unit="g",
                    example_serving="100.0 g",
                    current_serving_grams="100",
                    corrected_serving_grams="",
                    reference_calories="316",
                    reference_protein_g="10.5",
                    reference_carbs_g="59.3",
                    reference_fat_g="5.5",
                    confidence="",
                    notes="",
                ),
            ]
        )
        records = self._read_jsonl()

        assert result["created"] == DOUBLE_RECORD_COUNT
        assert result["branded_commercial"] == DOUBLE_RECORD_COUNT
        assert [record["name"] for record in records] == [
            "Choco Pie",
            "Bonn multigrain sub bread",
        ]

    def test_skips_matched_exception_and_other_deferred_rows(self) -> None:
        result = self._run(
            [
                _row(
                    description="Apple",
                    matched_food_id="apple-1",
                    reference_calories="104",
                    reference_protein_g="0.5",
                    reference_carbs_g="27.6",
                    reference_fat_g="0.3",
                    corrected_serving_grams="182",
                ),
                _row(
                    description="Roti",
                    row_count="242",
                    reference_calories="80",
                    reference_protein_g="2",
                    reference_carbs_g="13",
                    reference_fat_g="2",
                ),
            ]
        )

        assert result["created"] == 0
        assert result["deferred"] == 1
        assert self._read_jsonl() == []

    def test_keeps_per_100ml_basis_traceability(self) -> None:
        self._run(
            [
                _row(
                    description="Soy milk",
                    serving_mode="volume",
                    reference_basis="per_100ml",
                    row_count="6",
                    example_value="100",
                    example_unit="ml",
                    example_serving="1.0 mL",
                    corrected_serving_grams="1",
                    reference_calories="53.9",
                    reference_protein_g="3.5",
                    reference_carbs_g="5.3",
                    reference_fat_g="2.1",
                )
            ]
        )
        records = self._read_jsonl()

        assert records[0]["serving_size_g"] == ML_BASIS_GRAMS
        assert records[0]["default_unit"] == "ml"
        assert records[0]["servings"] == [
            {"label": "100 ml", "quantity": 100, "unit": "ml", "grams": 100}
        ]
        assert records[0]["provenance"]["reference_basis"] == "per_100ml"

    def test_all_unmatched_mode_includes_non_policy_rows(self) -> None:
        result = self._run_all_unmatched(
            [
                _row(
                    description="Roti",
                    row_count="242",
                    reference_calories="80",
                    reference_protein_g="2",
                    reference_carbs_g="13",
                    reference_fat_g="2",
                ),
                _row(
                    description="Apple",
                    matched_food_id="apple-1",
                    reference_calories="104",
                    reference_protein_g="0.5",
                    reference_carbs_g="27.6",
                    reference_fat_g="0.3",
                    corrected_serving_grams="182",
                ),
            ]
        )
        records = self._read_jsonl()

        assert result["created"] == 1
        assert result["deferred"] == 0
        assert records[0]["name"] == "Roti"
        assert records[0]["provenance"]["selection_reason"] == (
            "all_unmatched_no_safe_existing_match"
        )


if __name__ == "__main__":
    unittest.main()
