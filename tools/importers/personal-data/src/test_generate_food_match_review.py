"""Tests for Step 10: generate_food_match_review."""

from __future__ import annotations

import csv
import json
import os
import tempfile
import unittest
from decimal import Decimal

from steps.generate_food_match_review import (
    ProductCandidate,
    ProductServing,
    _normalize_description,
    _search_terms,
    run,
)

BASE_FIELDS = [
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
]


def _write_csv(rows: list[dict[str, str]], fieldnames: list[str] | None = None) -> str:
    fieldnames = fieldnames or list(rows[0].keys())
    with tempfile.NamedTemporaryFile(
        "w",
        newline="",
        delete=False,
        suffix=".csv",
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
        return handle.name


def _temp_path(suffix: str) -> str:
    fd, path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    return path


def _base_row(**overrides: str) -> dict[str, str]:
    row = dict.fromkeys(BASE_FIELDS, "")
    row.update(
        {
            "description": "Rice",
            "row_count": "3",
            "serving_mode": "mass",
            "reference_basis": "per_100g",
            "reference_calories": "130",
            "reference_protein_g": "2.4",
            "reference_carbs_g": "28.7",
            "reference_fat_g": "0.3",
            "example_value": "100",
            "example_unit": "g",
            "example_serving": "100.0 g",
            "current_serving_grams": "100",
        }
    )
    row.update(overrides)
    return row


class FakeRepo:
    def __init__(self, mapping: dict[str, list[ProductCandidate]]) -> None:
        self.mapping = mapping

    def search_global_products(self, search_terms: list[str]) -> list[ProductCandidate]:
        candidates: list[ProductCandidate] = []
        seen_ids: set[str] = set()
        for term in search_terms:
            for candidate in self.mapping.get(term, []):
                if candidate.id in seen_ids:
                    continue
                seen_ids.add(candidate.id)
                candidates.append(candidate)
        return candidates


def _candidate(
    *,
    product_id: str,
    name: str,
    energy: str,
    protein: str,
    carbs: str,
    fat: str,
    serving_size_g: str | None = None,
    servings: list[ProductServing] | None = None,
) -> ProductCandidate:
    return ProductCandidate(
        id=product_id,
        name=name,
        brand=None,
        serving_size_g=Decimal(serving_size_g) if serving_size_g else None,
        nutrients_per_100g={
            "ENERGY_KCAL": Decimal(energy),
            "PROTEIN_G": Decimal(protein),
            "CARBS_G": Decimal(carbs),
            "FAT_G": Decimal(fat),
        },
        servings=servings or [],
    )


class GenerateFoodMatchReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.input_path: str | None = None
        self.output_path: str | None = None
        self.existing_path: str | None = None
        self.jsonl_path: str | None = None

    def tearDown(self) -> None:
        for path in [
            self.input_path,
            self.output_path,
            self.existing_path,
            self.jsonl_path,
        ]:
            if path and os.path.exists(path):
                os.unlink(path)

    def _run(
        self,
        rows: list[dict[str, str]],
        repo: FakeRepo,
        *,
        existing_rows: list[dict[str, str]] | None = None,
    ) -> dict[str, str | int]:
        self.input_path = _write_csv(rows)
        self.output_path = _temp_path(".csv")
        self.jsonl_path = _temp_path(".jsonl")
        if existing_rows is not None:
            self.existing_path = _write_csv(
                existing_rows,
                list(existing_rows[0].keys()),
            )
        return run(
            self.input_path,
            self.output_path,
            existing_review_path=self.existing_path,
            matches_jsonl_path=self.jsonl_path,
            repo=repo,
        )

    def _read_csv(self) -> list[dict[str, str]]:
        with open(self.output_path, newline="", encoding="utf-8") as handle:
            return list(csv.DictReader(handle))

    def _read_jsonl(self) -> list[dict[str, str]]:
        with open(self.jsonl_path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_auto_matches_exact_name_and_macros(self) -> None:
        repo = FakeRepo(
            {
                "Rice": [
                    _candidate(
                        product_id="food-1",
                        name="Rice",
                        energy="130",
                        protein="2.4",
                        carbs="28.7",
                        fat="0.3",
                    ),
                ],
            },
        )
        result = self._run([_base_row()], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "food-1"
        assert rows[0]["matched_food_name"] == "Rice"
        assert rows[0]["match_confidence"] == "high"
        assert "macro agreement" in rows[0]["match_basis"]
        jsonl = self._read_jsonl()
        assert jsonl[0]["matched_food_id"] == "food-1"

    def test_rejects_name_match_when_macros_drift(self) -> None:
        repo = FakeRepo(
            {
                "Rice": [
                    _candidate(
                        product_id="food-1",
                        name="Rice",
                        energy="190",
                        protein="2.4",
                        carbs="40",
                        fat="3",
                    ),
                ],
            },
        )
        result = self._run([_base_row()], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 0
        assert rows[0]["matched_food_id"] == ""
        assert self._read_jsonl() == []

    def test_rejects_weak_name_even_if_macros_match(self) -> None:
        repo = FakeRepo(
            {
                "Rice": [
                    _candidate(
                        product_id="food-1",
                        name="Quinoa Bowl",
                        energy="130",
                        protein="2.4",
                        carbs="28.7",
                        fat="0.3",
                    ),
                ],
            },
        )
        self._run([_base_row()], repo)
        rows = self._read_csv()
        assert rows[0]["matched_food_id"] == ""

    def test_matches_per_serving_when_serving_grams_align(self) -> None:
        repo = FakeRepo(
            {
                "Boiled Egg": [
                    _candidate(
                        product_id="egg-1",
                        name="Boiled Egg",
                        energy="143",
                        protein="12.6",
                        carbs="0.7",
                        fat="9.5",
                        servings=[
                            ProductServing(
                                label="1 egg",
                                quantity=Decimal(1),
                                unit="serving",
                                grams=Decimal(50),
                            ),
                        ],
                    ),
                ],
            },
        )
        row = _base_row(
            description="Boiled Egg",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="71.5",
            reference_protein_g="6.3",
            reference_carbs_g="0.4",
            reference_fat_g="4.8",
            current_serving_grams="50",
            example_unit="serving",
            example_serving="1.0 egg",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "egg-1"
        assert "derived from serving grams 50g" in rows[0]["match_notes"]

    def test_volume_basis_matches_exact_liquid_name(self) -> None:
        repo = FakeRepo(
            {
                "Milk": [
                    _candidate(
                        product_id="milk-1",
                        name="Milk",
                        energy="42",
                        protein="3.4",
                        carbs="5",
                        fat="1",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Milk",
            serving_mode="volume",
            reference_basis="per_100ml",
            reference_calories="42",
            reference_protein_g="3.4",
            reference_carbs_g="5",
            reference_fat_g="1",
            current_serving_grams="",
            example_unit="ml",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "milk-1"
        assert rows[0]["match_basis"] == "exact/strong liquid name + macro agreement"

    def test_per_serving_matches_by_derived_per_100g_without_candidate_serving(
        self,
    ) -> None:
        repo = FakeRepo(
            {
                "Banana": [
                    _candidate(
                        product_id="banana-1",
                        name="Banana",
                        energy="97",
                        protein="0.8",
                        carbs="22.7",
                        fat="0.25",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Banana",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="114.5",
            reference_protein_g="0.9",
            reference_carbs_g="26.8",
            reference_fat_g="0.3",
            corrected_serving_grams="118",
            example_unit="serving",
            example_serving='1.0 medium (7" to 7-7/8" long)',
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "banana-1"

    def test_unmatched_rows_record_top_candidates(self) -> None:
        repo = FakeRepo(
            {
                "Rice": [
                    _candidate(
                        product_id="food-1",
                        name="Rice",
                        energy="190",
                        protein="2.4",
                        carbs="40",
                        fat="3",
                    ),
                ],
            },
        )
        self._run([_base_row()], repo)
        rows = self._read_csv()
        assert rows[0]["matched_food_id"] == ""
        assert rows[0]["match_notes"].startswith("top candidates: Rice")

    def test_search_terms_include_aliases(self) -> None:
        terms = _search_terms("Bhindi (Okra)")
        assert "okra" in terms
        assert any("okra" in term for term in terms)

    def test_preserves_existing_manual_match(self) -> None:
        repo = FakeRepo({})
        existing_rows = [
            {
                **_base_row(),
                "matched_food_id": "food-9",
                "matched_food_name": "Rice, cooked",
                "match_confidence": "high",
                "match_basis": "manual",
                "match_notes": "preserved",
            },
        ]
        result = self._run([_base_row()], repo, existing_rows=existing_rows)
        rows = self._read_csv()
        assert result["preserved_existing_matches"] == 1
        assert rows[0]["matched_food_id"] == "food-9"
        assert self._read_jsonl()[0]["matched_food_id"] == "food-9"

    def test_normalize_description_is_stable(self) -> None:
        assert _normalize_description("AS Protein Bread (48 gms)") == "as protein bread"


if __name__ == "__main__":
    unittest.main()
