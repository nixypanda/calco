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
from mfp_nutrients import REQUIRED_REVIEW_REFERENCE_COLUMNS

BASE_FIELDS = [
    "description",
    "row_count",
    "serving_mode",
    "reference_basis",
    *REQUIRED_REVIEW_REFERENCE_COLUMNS,
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

    def find_global_product_by_barcode(self, barcode: str) -> ProductCandidate | None:
        for candidates in self.mapping.values():
            for candidate in candidates:
                if candidate.id == barcode:
                    return candidate
        return None


def _candidate(
    *,
    product_id: str,
    name: str,
    energy: str,
    protein: str,
    carbs: str,
    fat: str,
    servings: list[ProductServing] | None = None,
    default_quantity: Decimal | None = None,
    default_unit: str | None = None,
) -> ProductCandidate:
    return ProductCandidate(
        id=product_id,
        name=name,
        brand=None,
        default_quantity=default_quantity,
        default_unit=default_unit,
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
        barcode_hints: dict[str, str] | None = None,
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
            barcode_hints=barcode_hints,
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
                                unit="serving",
                                grams_per_unit=Decimal(50),
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

    def test_match_notes_use_candidate_default_portion_weight(self) -> None:
        repo = FakeRepo(
            {
                "Snack": [
                    _candidate(
                        product_id="snack-1",
                        name="Snack",
                        energy="300",
                        protein="10",
                        carbs="40",
                        fat="10",
                        default_quantity=Decimal(3),
                        default_unit="piece",
                        servings=[
                            ProductServing(
                                unit="piece",
                                grams_per_unit=Decimal(14),
                            ),
                        ],
                    ),
                ],
            },
        )
        row = _base_row(
            description="Snack",
            reference_basis="per_serving",
            reference_calories="126",
            reference_protein_g="4.2",
            reference_carbs_g="16.8",
            reference_fat_g="4.2",
            current_serving_grams="42",
        )

        result = self._run([row], repo)
        rows = self._read_csv()

        assert result["auto_matched"] == 1
        assert "candidate default portion '3 piece' 42g" in rows[0]["match_notes"]

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

    def test_matches_from_barcode_hint(self) -> None:
        ferrero = _candidate(
            product_id="8000500126936",
            name="Ferrero Rocher",
            energy="584",
            protein="8",
            carbs="48",
            fat="40",
        )
        repo = FakeRepo(
            {
                "Ferrero Rocher": [ferrero],
            },
        )
        result = self._run(
            [
                _base_row(
                    description="Ferrero Rocher",
                    reference_basis="per_serving",
                    reference_calories="75.6",
                    reference_protein_g="1",
                    reference_carbs_g="5.9",
                    reference_fat_g="5.3",
                    example_serving="2.0 pieces",
                    current_serving_grams="",
                ),
            ],
            repo,
            barcode_hints={"Ferrero Rocher": "8000500126936"},
        )
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "8000500126936"
        assert rows[0]["matched_food_name"] == "Ferrero Rocher"
        assert rows[0]["match_basis"] == "barcode lookup"
        assert "8000500126936" in rows[0]["match_notes"]

    def test_search_terms_include_aliases(self) -> None:
        terms = _search_terms("Bhindi (Okra)")
        assert "okra" in terms
        assert any("okra" in term for term in terms)

    def test_search_terms_include_step_10_aliases(self) -> None:
        assert "whey protein" in _search_terms("Whey")
        roti_terms = _search_terms("Roti")
        assert "chapati" in roti_terms
        assert "phulka" in roti_terms
        assert "flatbread" in roti_terms
        brest_terms = _search_terms("Brest")
        assert "chicken breast" in brest_terms

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

    def test_preserves_existing_manual_match_from_legacy_review_columns(self) -> None:
        repo = FakeRepo({})
        existing_rows = [
            {
                "description": "Rice",
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
        assert rows[0]["matched_food_name"] == "Rice, cooked"

    def test_rejects_legacy_review_csv_without_full_nutrient_columns(self) -> None:
        legacy_fields = [field for field in BASE_FIELDS if field != "reference_fiber_g"]
        legacy_row = {
            field: value
            for field, value in _base_row().items()
            if field in legacy_fields
        }
        self.input_path = _write_csv([legacy_row], legacy_fields)
        self.output_path = _temp_path(".csv")
        self.jsonl_path = _temp_path(".jsonl")

        with self.assertRaisesRegex(
            ValueError,
            "missing required full-nutrient columns",
        ):
            run(
                self.input_path,
                self.output_path,
                matches_jsonl_path=self.jsonl_path,
                repo=FakeRepo({}),
                barcode_hints={},
            )

    def test_normalize_description_is_stable(self) -> None:
        assert _normalize_description("AS Protein Bread (48 gms)") == "as protein bread"

    def test_matches_egg_white_with_tiny_zeroish_macro_drift(self) -> None:
        repo = FakeRepo(
            {
                "Egg White": [
                    _candidate(
                        product_id="egg-white-1",
                        name="Egg, white, raw, fresh",
                        energy="52",
                        protein="10.9",
                        carbs="0.7",
                        fat="0.2",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Egg White",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="17",
            reference_protein_g="3.6",
            reference_carbs_g="0.2",
            reference_fat_g="0.1",
            corrected_serving_grams="33",
            example_unit="serving",
            example_serving="1.0 egg white",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "egg-white-1"

    def test_matches_banana_with_wider_protein_tolerance(self) -> None:
        repo = FakeRepo(
            {
                "Banana": [
                    _candidate(
                        product_id="banana-1",
                        name="Bananas, raw",
                        energy="89",
                        protein="1.1",
                        carbs="22.8",
                        fat="0.3",
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

    def test_matches_apple_by_name_token_when_macros_are_close(self) -> None:
        repo = FakeRepo(
            {
                "Apple": [
                    _candidate(
                        product_id="apple-1",
                        name="Apple, raw, with skin",
                        energy="52",
                        protein="0.3",
                        carbs="13.8",
                        fat="0.2",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Apple",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="95",
            reference_protein_g="0.5",
            reference_carbs_g="25.1",
            reference_fat_g="0.3",
            corrected_serving_grams="182",
            example_unit="serving",
            example_serving="1.0 medium",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "apple-1"
        assert rows[0]["match_basis"] == "apple name token + macro agreement"

    def test_does_not_match_apple_when_macros_are_not_close(self) -> None:
        repo = FakeRepo(
            {
                "Apple": [
                    _candidate(
                        product_id="apple-1",
                        name="Apple Pie Filling",
                        energy="120",
                        protein="0.5",
                        carbs="30",
                        fat="2",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Apple",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="95",
            reference_protein_g="0.5",
            reference_carbs_g="25.1",
            reference_fat_g="0.3",
            corrected_serving_grams="182",
            example_unit="serving",
            example_serving="1.0 medium",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 0
        assert rows[0]["matched_food_id"] == ""

    def test_matches_greek_yogurt_natural_with_dairy_tolerance(self) -> None:
        repo = FakeRepo(
            {
                "Greek Yogurt, Natural": [
                    _candidate(
                        product_id="greek-1",
                        name="Greek Yogurt Natural",
                        energy="76",
                        protein="9.3",
                        carbs="5.2",
                        fat="2",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Greek Yogurt, Natural",
            reference_basis="per_100g",
            reference_calories="71.4",
            reference_protein_g="8.2",
            reference_carbs_g="3.9",
            reference_fat_g="2.6",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "greek-1"

    def test_matches_exact_liquid_name_with_wider_almond_milk_tolerance(self) -> None:
        repo = FakeRepo(
            {
                "Almond Milk, Plain": [
                    _candidate(
                        product_id="almond-milk-1",
                        name="Almond Milk",
                        energy="33",
                        protein="1.3",
                        carbs="0.7",
                        fat="2.8",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Almond Milk, Plain",
            serving_mode="volume",
            reference_basis="per_100ml",
            reference_calories="47.2",
            reference_protein_g="2",
            reference_carbs_g="1.1",
            reference_fat_g="3.9",
            corrected_serving_grams="250",
            example_unit="ml",
            example_serving="250.0 ml",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "almond-milk-1"

    def test_matches_whey_protein_with_alias_and_supplement_tolerance(self) -> None:
        repo = FakeRepo(
            {
                "whey protein": [
                    _candidate(
                        product_id="whey-1",
                        name="Whey Protein",
                        energy="394.3",
                        protein="80",
                        carbs="8.3",
                        fat="4.9",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Whey",
            serving_mode="serving_unit",
            reference_basis="per_serving",
            reference_calories="120",
            reference_protein_g="24",
            reference_carbs_g="3",
            reference_fat_g="1",
            corrected_serving_grams="30",
            example_unit="serving",
            example_serving="1.0 scoop",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "whey-1"

    def test_matches_brest_via_breast_alias(self) -> None:
        repo = FakeRepo(
            {
                "chicken breast": [
                    _candidate(
                        product_id="breast-1",
                        name="Chicken breast, cooked",
                        energy="195",
                        protein="29.5",
                        carbs="0",
                        fat="7.7",
                    ),
                ],
            },
        )
        row = _base_row(
            description="Brest",
            reference_basis="per_100g",
            reference_calories="195",
            reference_protein_g="29.5",
            reference_carbs_g="0",
            reference_fat_g="7.7",
        )
        result = self._run([row], repo)
        rows = self._read_csv()
        assert result["auto_matched"] == 1
        assert rows[0]["matched_food_id"] == "breast-1"


if __name__ == "__main__":
    unittest.main()
