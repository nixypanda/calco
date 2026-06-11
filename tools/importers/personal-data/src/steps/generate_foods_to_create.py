"""Step 13: Build JSONL for approved unmatched custom-food creations."""

from __future__ import annotations

import csv
import json
import re
from decimal import Decimal, InvalidOperation
from pathlib import Path

BRANDED_COMMERCIAL_DESCRIPTIONS = (
    "multi-protein bread",
    "48 gms protein bread",
    "Wild Blueberry Fruit Spread",
    "Four Fruits Fruit Spread",
    "Strawberry Fruit Spread",
    "Choco Pie",
    "Protein Bar",
    "Masala cup noodles",
    "Kitkat Milk Chocolate Candy Bar",
    "Double Cocoa Protein Pro",
    "Coke Zero",
    "Corona Extra Can",
    "Bonn multigrain sub bread",
    "B-Ready",
    "Belgian Waffle",
    "Belgian Waffle With Nutella",
    "Paul Sandwich Sesame Camembert",
    "PRO Bowl - Grilled Barbeque Chicken",
    "PRO Salad - Mexican Paneer",
)
RAW_BASIC_DESCRIPTIONS = (
    "Whey",
    "Bread",
    "Paneer",
    "Muskmelon",
    "Soy milk",
    "tofu",
)
MATCH_EXCEPTION_DESCRIPTIONS = ("Apple",)
POLICY_COLUMN_ORDER = (
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
)
NUTRIENT_COLUMNS = (
    ("ENERGY_KCAL", "reference_calories"),
    ("PROTEIN_G", "reference_protein_g"),
    ("CARBS_G", "reference_carbs_g"),
    ("FAT_G", "reference_fat_g"),
)
SPACE_RE = re.compile(r"\s+")
MFP_BRAND = "MyFitnessPal"
MFP_CATEGORIES = ["mfp-import"]
CONFIDENCE = "reviewed"
BASIS_100 = Decimal(100)


def _normalize_description(value: str) -> str:
    return SPACE_RE.sub(" ", value.replace("\xa0", " ")).strip().casefold()


def _clean_text(value: str) -> str:
    return SPACE_RE.sub(" ", value.replace("\xa0", " ")).strip()


BRANDED_COMMERCIAL_KEYS = {
    _normalize_description(value) for value in BRANDED_COMMERCIAL_DESCRIPTIONS
}
RAW_BASIC_KEYS = {_normalize_description(value) for value in RAW_BASIC_DESCRIPTIONS}
MATCH_EXCEPTION_KEYS = {
    _normalize_description(value) for value in MATCH_EXCEPTION_DESCRIPTIONS
}


def _parse_decimal(value: str) -> Decimal | None:
    text = value.strip()
    if not text:
        return None
    try:
        return Decimal(text)
    except InvalidOperation as exc:
        message = f"Invalid decimal value: {value!r}"
        raise ValueError(message) from exc


def _required_serving_grams(row: dict[str, str]) -> Decimal:
    for column in ("corrected_serving_grams", "current_serving_grams"):
        value = _parse_decimal(row.get(column, ""))
        if value is not None and value > 0:
            return value
    description = _clean_text(row["description"])
    message = f"Missing serving grams for per-serving row: {description}"
    raise ValueError(message)


def _basis_serving_grams(row: dict[str, str]) -> Decimal:
    basis = row["reference_basis"].strip()
    if basis == "per_100g":
        return BASIS_100
    if basis == "per_100ml":
        return BASIS_100
    if basis == "per_serving":
        return _required_serving_grams(row)
    message = f"Unsupported reference basis: {basis!r}"
    raise ValueError(message)


def _amount_per_100g(row: dict[str, str], column: str) -> Decimal | None:
    amount = _parse_decimal(row.get(column, ""))
    if amount is None:
        return None
    basis = row["reference_basis"].strip()
    if basis in {"per_100g", "per_100ml"}:
        return amount
    if basis == "per_serving":
        serving_grams = _required_serving_grams(row)
        return (amount * BASIS_100) / serving_grams
    message = f"Unsupported reference basis: {basis!r}"
    raise ValueError(message)


def _json_number(value: Decimal) -> int | float:
    normalized = value.normalize()
    if normalized == normalized.to_integral():
        return int(normalized)
    return float(round(value, 4))


def _servings(row: dict[str, str]) -> list[dict[str, int | float | str]]:
    basis = row["reference_basis"].strip()
    if basis == "per_serving":
        grams = _required_serving_grams(row)
        label = _clean_text(row.get("example_serving", "")) or "1 serving"
        return [
            {
                "label": label,
                "quantity": 1,
                "unit": "serving",
                "grams": _json_number(grams),
            }
        ]
    if basis == "per_100ml":
        return [{"label": "100 ml", "quantity": 100, "unit": "ml", "grams": 100}]
    return [{"label": "100 g", "quantity": 100, "unit": "g", "grams": 100}]


def _default_unit(row: dict[str, str]) -> str:
    basis = row["reference_basis"].strip()
    if basis == "per_serving":
        return "serving"
    if basis == "per_100ml":
        return "ml"
    return "g"


def _policy_bucket(row: dict[str, str]) -> str | None:
    normalized = _normalize_description(row["description"])
    if normalized in BRANDED_COMMERCIAL_KEYS:
        return "branded_commercial"
    if normalized in RAW_BASIC_KEYS:
        return "raw_basic"
    return None


def _should_create(row: dict[str, str]) -> bool:
    if row.get("matched_food_id", "").strip():
        return False
    normalized = _normalize_description(row["description"])
    if normalized in MATCH_EXCEPTION_KEYS:
        return False
    return _policy_bucket(row) is not None


def _is_unmatched(row: dict[str, str]) -> bool:
    return not row.get("matched_food_id", "").strip()


def _build_record(row: dict[str, str], input_path: str | Path) -> dict[str, object]:
    description = _clean_text(row["description"])
    serving_grams = _basis_serving_grams(row)
    nutrients = []
    reference_nutrients: dict[str, int | float] = {}
    for code, column in NUTRIENT_COLUMNS:
        reference_amount = _parse_decimal(row.get(column, ""))
        if reference_amount is None:
            continue
        per_100g_amount = _amount_per_100g(row, column)
        if per_100g_amount is None:
            continue
        nutrients.append(
            {
                "code": code,
                "amount_per_100g": _json_number(per_100g_amount),
                "source": "mfp",
                "confidence": CONFIDENCE,
            }
        )
        reference_nutrients[code] = _json_number(reference_amount)

    return {
        "name": description,
        "brand": MFP_BRAND,
        "categories": MFP_CATEGORIES,
        "serving_size_g": _json_number(serving_grams),
        "default_quantity": 1,
        "default_unit": _default_unit(row),
        "nutrients": nutrients,
        "servings": _servings(row),
        "provenance": {
            "source_review_csv": str(input_path),
            "source_description": description,
            "row_count": int(row["row_count"]),
            "policy_bucket": _policy_bucket(row),
            "selection_reason": (
                "approved_policy_bucket"
                if _policy_bucket(row) is not None
                else "all_unmatched_no_safe_existing_match"
            ),
            "serving_mode": row["serving_mode"],
            "reference_basis": row["reference_basis"],
            "reference_nutrients": reference_nutrients,
            "reviewed_serving_grams": _json_number(serving_grams),
            "example_value": _clean_text(row.get("example_value", "")),
            "example_unit": _clean_text(row.get("example_unit", "")),
            "example_serving": _clean_text(row.get("example_serving", "")),
            "confidence": _clean_text(row.get("confidence", "")),
            "notes": _clean_text(row.get("notes", "")),
        },
    }


def run(
    input_path: str | Path,
    output_path: str | Path,
    *,
    selection: str = "approved-policy",
) -> dict[str, int]:
    with Path(input_path).open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    if selection == "approved-policy":
        selected_rows = [row for row in rows if _should_create(row)]
    elif selection == "all-unmatched":
        selected_rows = [row for row in rows if _is_unmatched(row)]
    else:
        message = f"Unsupported selection mode: {selection!r}"
        raise ValueError(message)

    output_records = [
        _build_record(row, input_path)
        for row in selected_rows
    ]

    branded_count = sum(
        1
        for record in output_records
        if record["provenance"]["policy_bucket"] == "branded_commercial"
    )
    raw_basic_count = sum(
        1
        for record in output_records
        if record["provenance"]["policy_bucket"] == "raw_basic"
    )
    unmatched_total = sum(
        1 for row in rows if not row.get("matched_food_id", "").strip()
    )

    with Path(output_path).open("w", encoding="utf-8", newline="") as handle:
        for record in output_records:
            handle.write(json.dumps(record, ensure_ascii=False))
            handle.write("\n")

    return {
        "created": len(output_records),
        "branded_commercial": branded_count,
        "raw_basic": raw_basic_count,
        "deferred": unmatched_total - len(selected_rows),
    }
