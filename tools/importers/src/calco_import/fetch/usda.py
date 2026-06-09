import json
import logging
import os
import time
import zipfile
from collections.abc import Iterator

from calco_import.fetch import MAPPING_DIR
from calco_import.fetch._download import download_file
from calco_import.util import parse_amount, write_jsonl_row

log = logging.getLogger(__name__)

USDA_ZIP_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/"
    "FoodData_Central_sr_legacy_food_json_2018-04.zip"
)


def _load_usda_zip(zip_path: str) -> list[dict]:
    with zipfile.ZipFile(zip_path, "r") as z:
        json_files = [n for n in z.namelist() if n.endswith(".json")]
        if not json_files:
            log.error("No JSON file found in zip archive: %s", zip_path)
            return []
        with z.open(json_files[0]) as f:
            data = json.load(f)

    if isinstance(data, dict):
        return data.get(
            "FoundationFoods",
            data.get("SRLegacyFoods", data.get("Foods", [])),
        )
    if isinstance(data, list):
        return data
    return []


def _build_food_row(food: dict) -> dict | None:
    fdc_id = str(food.get("fdcId", ""))
    description = food.get("description", "")
    if not fdc_id or not description:
        return None

    food_category = food.get("foodCategory")
    if isinstance(food_category, dict):
        category = food_category.get("description", "")
    elif isinstance(food_category, str):
        category = food_category
    else:
        category = food.get("foodCategoryId", "")

    brand = food.get("brandName") or food.get("brandOwner") or None
    serving_size = food.get("servingSize")
    if serving_size is not None:
        try:
            serving_size = float(serving_size)
        except (ValueError, TypeError):
            serving_size = None

    return {
        "type": "food",
        "source": "USDA",
        "source_id": fdc_id,
        "name": description,
        "brand": brand,
        "categories": [str(category).strip().lower()] if category else [],
        "serving_size_g": serving_size,
    }


def _build_serving_rows(food: dict, fdc_id: str) -> Iterator[dict]:
    seen: set[tuple[str, str]] = set()
    for portion in food.get("foodPortions", []):
        gram_weight = parse_amount(portion.get("gramWeight"))
        amount = parse_amount(portion.get("amount"))
        if gram_weight is None or amount is None or gram_weight <= 0 or amount <= 0:
            continue
        measure_unit = portion.get("measureUnit") or {}
        raw_unit = (
            measure_unit.get("abbreviation")
            or measure_unit.get("name")
            or portion.get("modifier")
            or "serving"
        )
        unit = (raw_unit or "serving").strip()
        if not unit or unit.lower() == "undetermined":
            unit = "serving"
        label = portion.get("portionDescription") or portion.get("modifier") or unit
        label = (label or "serving").strip()[:80] or "serving"
        key = (label, unit)
        if key in seen:
            continue
        seen.add(key)
        yield {
            "type": "serving",
            "source": "USDA",
            "source_id": fdc_id,
            "label": label,
            "quantity": amount,
            "unit": unit,
            "grams": gram_weight,
        }


def _build_nutrient_rows(food: dict, fdc_id: str, nutrient_map: dict) -> Iterator[dict]:
    for nutr in food.get("foodNutrients", []):
        n_obj = nutr.get("nutrient", {})
        nutrient_id = str(n_obj.get("number", n_obj.get("id", "")))
        if nutrient_id not in nutrient_map:
            continue
        amount = parse_amount(nutr.get("amount"))
        if amount is None:
            continue
        yield {
            "type": "nutrient",
            "source": "USDA",
            "source_id": fdc_id,
            "nutrient_code": nutrient_map[nutrient_id],
            "amount_per_100g": amount,
        }


def fetch_usda(data_dir: str) -> None:
    raw_dir = os.path.join(data_dir, "raw")
    processed_dir = os.path.join(data_dir, "processed")
    zip_path = os.path.join(raw_dir, "usda_sr_legacy.zip")
    out_path = os.path.join(processed_dir, "usda_sr_legacy.jsonl")

    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(processed_dir, exist_ok=True)

    mapping_path = os.path.join(MAPPING_DIR, "usda_sr_codes.json")
    with open(mapping_path) as f:
        nutrient_map = json.load(f)

    if not os.path.exists(zip_path):
        download_file(USDA_ZIP_URL, zip_path)

    start = time.time()
    total_foods = 0
    total_nutrients = 0
    total_servings = 0

    foods = _load_usda_zip(zip_path)

    with open(out_path, "w") as out:
        for food in foods:
            food_row = _build_food_row(food)
            if food_row is None:
                continue
            write_jsonl_row(out, food_row)
            total_foods += 1
            fdc_id = food_row["source_id"]

            for serving_row in _build_serving_rows(food, fdc_id):
                write_jsonl_row(out, serving_row)
                total_servings += 1

            for nutrient_row in _build_nutrient_rows(food, fdc_id, nutrient_map):
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

    elapsed = time.time() - start
    log.info(
        "USDA: %d foods, %d nutrients, %d servings -> %s (%.1fs)",
        total_foods,
        total_nutrients,
        total_servings,
        out_path,
        elapsed,
    )
