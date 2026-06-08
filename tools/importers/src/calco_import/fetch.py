import csv
import gzip
import json
import logging
import os
import re
import sys
import time
import zipfile

import requests
import tqdm

from calco_import.util import parse_amount, write_jsonl_row

log = logging.getLogger(__name__)

MAPPING_DIR = os.path.join(
    os.path.dirname(__file__), "..", "..", "nutrient_mapping",
)

USDA_ZIP_URL = (
    "https://fdc.nal.usda.gov/fdc-datasets/"
    "FoodData_Central_sr_legacy_food_json_2018-04.zip"
)
OFF_GZ_URL = "https://static.openfoodfacts.org/data/off_products.csv.gz"
REQUIRED_OFF_FIELDS = [
    "energy-kcal_100g",
    "proteins_100g",
    "carbohydrates_100g",
    "fat_100g",
]
SCAN_LOG_INTERVAL = 500_000

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


def download_file(url: str, dest: str) -> None:
    if os.path.exists(dest):
        log.info("File already exists at %s, skipping download", dest)
        return
    log.info("Downloading %s ...", url)
    resp = requests.get(url, stream=True, timeout=300)
    resp.raise_for_status()
    total = int(resp.headers.get("content-length", 0))
    with (
        open(dest, "wb") as f,
        tqdm.tqdm(
            total=total, unit="B", unit_scale=True,
            desc=os.path.basename(dest),
        ) as pbar,
    ):
        for chunk in resp.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
                pbar.update(len(chunk))


def fetch_usda(cfg: dict[str, object]) -> None:
    if cfg.get("dry_run"):
        log.info("Dry-run: would fetch USDA SR Legacy from %s", USDA_ZIP_URL)
        return

    data_dir = str(cfg["data_dir"])
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

    with zipfile.ZipFile(zip_path, "r") as z:
        json_files = [n for n in z.namelist() if n.endswith(".json")]
        if not json_files:
            log.error("No JSON file found in zip archive: %s", zip_path)
            return
        with z.open(json_files[0]) as f:
            data = json.load(f)

    if isinstance(data, dict):
        foods = data.get(
            "FoundationFoods",
            data.get("SRLegacyFoods", data.get("Foods", [])),
        )
    elif isinstance(data, list):
        foods = data
    else:
        foods = []

    with open(out_path, "w") as out:
        for food in foods:
            fdc_id = str(food.get("fdcId", ""))
            description = food.get("description", "")
            if not fdc_id or not description:
                continue

            food_category = food.get("foodCategory", None)
            if isinstance(food_category, dict):
                category = food_category.get("description", "")
            elif isinstance(food_category, str):
                category = food_category
            else:
                category = food.get("foodCategoryId", "")

            brand = food.get("brandName") or food.get("brandOwner") or None
            serving_size = food.get("servingSize", None)
            if serving_size is not None:
                try:
                    serving_size = float(serving_size)
                except (ValueError, TypeError):
                    serving_size = None

            food_row = {
                "type": "food",
                "source": "USDA",
                "source_id": fdc_id,
                "name": description,
                "brand": brand,
                "categories": [str(category).strip().lower()] if category else [],
                "serving_size_g": serving_size,
            }
            write_jsonl_row(out, food_row)
            total_foods += 1

            seen_serving_keys: set[tuple[str, str]] = set()
            for portion in food.get("foodPortions", []):
                gram_weight = parse_amount(portion.get("gramWeight"))
                amount = parse_amount(portion.get("amount"))
                if (
                    gram_weight is None or amount is None
                    or gram_weight <= 0 or amount <= 0
                ):
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
                label = (
                    portion.get("portionDescription")
                    or portion.get("modifier")
                    or unit
                )
                label = (label or "serving").strip()[:80] or "serving"
                key = (label, unit)
                if key in seen_serving_keys:
                    continue
                seen_serving_keys.add(key)
                serving_row = {
                    "type": "serving",
                    "source": "USDA",
                    "source_id": fdc_id,
                    "label": label,
                    "quantity": amount,
                    "unit": unit,
                    "grams": gram_weight,
                }
                write_jsonl_row(out, serving_row)
                total_servings += 1

            food_nutrients = food.get("foodNutrients", [])
            for nutr in food_nutrients:
                n_obj = nutr.get("nutrient", {})
                nutrient_id = str(n_obj.get("number", n_obj.get("id", "")))
                if nutrient_id not in nutrient_map:
                    continue
                amount = parse_amount(nutr.get("amount"))
                if amount is None:
                    continue
                nutrient_row = {
                    "type": "nutrient",
                    "source": "USDA",
                    "source_id": fdc_id,
                    "nutrient_code": nutrient_map[nutrient_id],
                    "amount_per_100g": amount,
                }
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


def countries_contain_india(countries_str: str | None) -> bool:
    if not countries_str:
        return False
    return "india" in countries_str.lower()


def passes_off_filter(row: dict[str, str | None]) -> bool:
    for field in REQUIRED_OFF_FIELDS:
        v = parse_amount(row.get(field))
        if v is None or v <= 0:
            return False
    return True


def scale_off_code(code: str) -> float:
    if code.endswith("_MG"):
        return 1000.0
    if code.endswith("_UG"):
        return 1_000_000.0
    return 1.0


def categories_from_csv(value: str | None) -> list[str]:
    cats: list[str] = []
    for raw in (value or "").split(","):
        normalized = raw.strip().lower()
        if normalized and normalized not in cats:
            cats.append(normalized)
    return cats


def fetch_off(cfg: dict[str, object]) -> None:
    if cfg.get("dry_run"):
        log.info("Dry-run: would fetch OFF India from %s", OFF_GZ_URL)
        return

    data_dir = str(cfg["data_dir"])
    raw_dir = os.path.join(data_dir, "raw")
    processed_dir = os.path.join(data_dir, "processed")
    gz_path = os.path.join(raw_dir, "off_products.csv.gz")
    out_path = os.path.join(processed_dir, "off_india.jsonl")

    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(processed_dir, exist_ok=True)

    mapping_path = os.path.join(MAPPING_DIR, "off_fields.json")
    with open(mapping_path) as f:
        nutrient_map = json.load(f)

    if not os.path.exists(gz_path):
        download_file(OFF_GZ_URL, gz_path)

    csv.field_size_limit(sys.maxsize)

    start = time.time()
    total_scanned = 0
    total_kept = 0
    total_nutrients = 0
    total_servings = 0

    with (
        gzip.open(gz_path, "rt", encoding="utf-8", errors="replace") as gz_f,
        open(out_path, "w") as out,
    ):
        reader = csv.DictReader(gz_f, delimiter="\t")

        for row in reader:
            total_scanned += 1

            if not countries_contain_india(row.get("countries_en", "")):
                continue
            if not passes_off_filter(row):
                continue

            code = row.get("code", "").strip()
            if not code:
                continue

            source_id = code
            barcode = code

            food_row = {
                "type": "food",
                "source": "OFF",
                "source_id": source_id,
                "barcode": barcode,
                "name": row.get("product_name", "").strip() or None,
                "brand": row.get("brands", "").strip() or None,
                "categories": categories_from_csv(row.get("categories", "")),
                "serving_size_g": None,
            }
            write_jsonl_row(out, food_row)
            total_kept += 1

            serving_grams = parse_amount(row.get("serving_quantity"))
            if serving_grams is not None and serving_grams > 0:
                serving_label = (
                    (row.get("serving_size") or "").strip()[:80] or "serving"
                )
                serving_row = {
                    "type": "serving",
                    "source": "OFF",
                    "source_id": source_id,
                    "label": serving_label,
                    "quantity": 1.0,
                    "unit": "serving",
                    "grams": serving_grams,
                }
                write_jsonl_row(out, serving_row)
                total_servings += 1

            for csv_field, calco_code in nutrient_map.items():
                v = parse_amount(row.get(csv_field))
                if v is None:
                    continue
                amount = round(v * scale_off_code(calco_code), 6)
                nutrient_row = {
                    "type": "nutrient",
                    "source": "OFF",
                    "source_id": source_id,
                    "nutrient_code": calco_code,
                    "amount_per_100g": amount,
                }
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

            if total_scanned % SCAN_LOG_INTERVAL == 0:
                log.info(
                    "Scanned %d rows, kept %d products...",
                    total_scanned,
                    total_kept,
                )

    elapsed = time.time() - start
    log.info(
        "OFF India: scanned %d, kept %d products, "
        "%d nutrients, %d servings -> %s (%.1fs)",
        total_scanned,
        total_kept,
        total_nutrients,
        total_servings,
        out_path,
        elapsed,
    )


def categories_from_value(value: str | None) -> list[str]:
    if not value:
        return []
    normalized = value.strip().lower()
    return [normalized] if normalized else []


def fetch_ifct(cfg: dict[str, object]) -> None:
    if cfg.get("dry_run"):
        log.info("Dry-run: check for IFCT CSV at data-dir/raw/")
        return

    data_dir = str(cfg["data_dir"])
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

            food_row = {
                "type": "food",
                "source": "IFCT",
                "source_id": code,
                "name": name,
                "brand": None,
                "categories": categories_from_value(category),
                "serving_size_g": None,
            }
            write_jsonl_row(out, food_row)
            total_foods += 1

            for ifct_code, calco_code in nutrient_map.items():
                v = parse_amount(row.get(ifct_code))
                if v is None:
                    continue
                nutrient_row = {
                    "type": "nutrient",
                    "source": "IFCT",
                    "source_id": code,
                    "nutrient_code": calco_code,
                    "amount_per_100g": v,
                }
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


def dispatch(cfg: dict[str, object], dataset: str) -> None:
    if dataset == "usda":
        fetch_usda(cfg)
    elif dataset == "off":
        fetch_off(cfg)
    elif dataset == "ifct":
        fetch_ifct(cfg)
