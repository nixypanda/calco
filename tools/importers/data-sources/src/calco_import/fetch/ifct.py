import csv
import json
import logging
import os
import re
import time
from collections.abc import Iterator

from calco_import.paths import MAPPING_DIR
from calco_import.util import parse_amount, write_jsonl_row

log = logging.getLogger(__name__)

IFCT_CSV_FILENAME = "ifct2017_compositions.csv"

FOOD_GROUP_MAP: dict[str, str] = {
    "Cereals and Millets": "cereals-millets",
    "Green Leafy Vegetables": "green-leafy-vegetables",
    "Other Vegetables": "other-vegetables",
    "Fruits": "fruits",
    "Roots and Tubers": "roots-tubers",
    "Legumes": "legumes",
    "Nuts and Oilseeds": "nuts-oilseeds",
    "Condiments and Spices": "condiments-spices",
    "Fats and Edible Oils": "fats-oils",
    "Sugar and Confectionery": "sugar-confectionery",
    "Milk and Milk Products": "milk-products",
    "Egg and Egg Products": "egg-products",
    "Poultry and Meat Products": "poultry-meat",
    "Fish and Fish Products": "fish-products",
    "Alcoholic Beverages": "alcoholic-beverages",
    "Non-Alcoholic Beverages": "non-alcoholic-beverages",
    "Miscellaneous": "miscellaneous",
    "Composite Foods": "composite-foods",
    "Infant and Toddler Foods": "infant-foods",
    "Snacks and Sweets": "snacks-sweets",
}

CATEGORY_REPLACE_SPACES = re.compile(r"[\s-]+")


def categories_from_value(value: str | None) -> list[str]:
    if not value:
        return []
    normalized = value.strip().lower()
    return [normalized] if normalized else []


def _build_ifct_food_row(
    code: str,
    name: str,
    category: str | None,
) -> dict:
    return {
        "type": "food",
        "source": "IFCT",
        "source_id": code,
        "name": name,
        "brand": None,
        "categories": categories_from_value(category),
    }


def _build_ifct_nutrient_rows(
    row: dict,
    code: str,
    nutrient_map: dict,
) -> Iterator[dict]:
    for ifct_code, calco_code in nutrient_map.items():
        v = parse_amount(row.get(ifct_code))
        if v is None:
            continue
        yield {
            "type": "nutrient",
            "source": "IFCT",
            "source_id": code,
            "nutrient_code": calco_code,
            "amount_per_100g": v,
        }


def fetch_ifct(data_dir: str) -> None:
    raw_dir = os.path.join(data_dir, "raw")
    processed_dir = os.path.join(data_dir, "processed")
    csv_path = os.path.join(raw_dir, IFCT_CSV_FILENAME)
    out_path = os.path.join(processed_dir, "ifct2017.jsonl")

    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(processed_dir, exist_ok=True)

    if not os.path.exists(csv_path):
        log.info(
            "IFCT CSV not found at %s. "
            "Download IFCT 2017 CSV from http://www.ifct2017.com/ "
            "and save it to %s",
            csv_path,
            csv_path,
        )
        return

    mapping_path = os.path.join(MAPPING_DIR, "ifct2017_codes.json")
    with open(mapping_path) as f:
        nutrient_map = json.load(f)

    start = time.time()
    total_foods = 0
    total_nutrients = 0

    with open(csv_path, encoding="utf-8") as csv_f, open(out_path, "w") as out:
        reader = csv.DictReader(csv_f)
        for row in reader:
            code = (row.get("code") or "").strip()
            name = (row.get("name") or "").strip()
            if not code or not name:
                continue

            grup = (row.get("grup") or "").strip()
            category = FOOD_GROUP_MAP.get(
                grup,
                CATEGORY_REPLACE_SPACES.sub("-", grup).lower() if grup else None,
            )

            food_row = _build_ifct_food_row(code, name, category)
            write_jsonl_row(out, food_row)
            total_foods += 1

            for nutrient_row in _build_ifct_nutrient_rows(row, code, nutrient_map):
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

    elapsed = time.time() - start
    log.info(
        "IFCT 2017: %d foods, %d nutrients -> %s (%.1fs)",
        total_foods,
        total_nutrients,
        out_path,
        elapsed,
    )
