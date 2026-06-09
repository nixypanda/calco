import csv
import json
import logging
import os
import re
import shlex
import subprocess
import sys
import time
import zipfile

import openpyxl
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
OFF_GZ_URL = (
    "https://openfoodfacts-ds.s3.eu-west-3.amazonaws.com/"
    "en.openfoodfacts.org.products.csv.gz"
)
REQUIRED_OFF_FIELDS = [
    "energy-kcal_100g",
    "proteins_100g",
    "carbohydrates_100g",
    "fat_100g",
]

INDB_XLSX_URL = (
    "https://www.anuvaad.org.in/wp-content/uploads/2020/07/"
    "Anuvaad_INDB_2024.11.xlsx"
)
INDB_XLSX_FILENAME = "Anuvaad_INDB_2024.11.xlsx"
INDB_PROCESSED_FILENAME = "indb_2024.jsonl"

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
    resp = requests.get(url, stream=True, timeout=300, headers={
        "User-Agent": "CalCo/1.0",
    })
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


def _keep_off_row(
    row: list[str],
    idx_countries: int,
    required_indices: list[int],
) -> bool:
    if not row[idx_countries] or "india" not in row[idx_countries].lower():
        return False
    for idx in required_indices:
        v = parse_amount(row[idx])
        if v is None or v <= 0:
            return False
    return True


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

    # Pre-filter with zcat+grep instead of iterating all 4.5M rows in Python
    # csv.reader (~150s). grep processes the full file at C speed, Python only
    # touches ~28K matching rows (~20s total).
    pipe_cmd = (
        f"zcat {shlex.quote(gz_path)}"
        ' | { read -r header; echo "$header"; grep -i india; }'
    )

    proc = subprocess.Popen(
        ["bash", "-c", pipe_cmd],
        stdout=subprocess.PIPE,
        text=True,
    )

    csv.field_size_limit(sys.maxsize)
    reader = csv.reader(proc.stdout, delimiter="\t")
    header = next(reader)

    idx_countries = header.index("countries_en")
    idx_code = header.index("code")
    idx_product = header.index("product_name")
    idx_brands = header.index("brands")
    idx_categories = header.index("categories")
    idx_serving_qty = header.index("serving_quantity")
    idx_serving_size = header.index("serving_size")

    required_indices = [header.index(f) for f in REQUIRED_OFF_FIELDS]
    nutrient_indices = {
        calco_code: header.index(csv_field)
        for csv_field, calco_code in nutrient_map.items()
    }

    start = time.time()
    total_kept = 0
    total_nutrients = 0
    total_servings = 0

    with open(out_path, "w") as out:
        for row in reader:
            if not _keep_off_row(row, idx_countries, required_indices):
                continue

            code = row[idx_code].strip()
            if not code:
                continue
            source_id = code
            barcode = code

            food_row = {
                "type": "food",
                "source": "OFF",
                "source_id": source_id,
                "barcode": barcode,
                "name": row[idx_product].strip() or None,
                "brand": row[idx_brands].strip() or None,
                "categories": categories_from_csv(row[idx_categories]),
                "serving_size_g": None,
            }
            write_jsonl_row(out, food_row)
            total_kept += 1

            serving_grams = parse_amount(row[idx_serving_qty])
            if serving_grams is not None and serving_grams > 0:
                serving_label = (
                    row[idx_serving_size].strip()[:80] or "serving"
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

            for calco_code, col_idx in nutrient_indices.items():
                v = parse_amount(row[col_idx])
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

    proc.stdout.close()
    ret = proc.wait()
    if ret not in (0, 1):
        log.warning("OFF filtering pipeline exited with code %d", ret)

    elapsed = time.time() - start
    log.info(
        "OFF India: kept %d products, "
        "%d nutrients, %d servings -> %s (%.1fs)",
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


def fetch_indb(cfg: dict[str, object]) -> None:
    if cfg.get("dry_run"):
        log.info("Dry-run: would fetch INDB from %s", INDB_XLSX_URL)
        return

    data_dir = str(cfg["data_dir"])
    raw_dir = os.path.join(data_dir, "raw")
    processed_dir = os.path.join(data_dir, "processed")
    xlsx_path = os.path.join(raw_dir, INDB_XLSX_FILENAME)
    out_path = os.path.join(processed_dir, INDB_PROCESSED_FILENAME)

    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(processed_dir, exist_ok=True)

    download_file(INDB_XLSX_URL, xlsx_path)

    mapping_path = os.path.join(MAPPING_DIR, "indb_codes.json")
    with open(mapping_path) as f:
        nutrient_map = json.load(f)

    start = time.time()
    total_foods = 0
    total_nutrients = 0
    total_servings = 0

    wb = openpyxl.load_workbook(xlsx_path, read_only=True)
    ws = wb["Sheet1"]
    rows_iter = ws.iter_rows(values_only=True)
    headers: list[str] = [str(h) if h is not None else "" for h in next(rows_iter)]
    col_index = {name: i for i, name in enumerate(headers)}

    with open(out_path, "w") as out:
        for row in rows_iter:
            if row[0] is None or str(row[0]).strip() == "":
                continue

            source_id = str(row[col_index["food_code"]]).strip()
            name = str(row[col_index["food_name"]] or "").strip()
            if not source_id or not name:
                continue

            food_row = {
                "type": "food",
                "source": "INDB",
                "source_id": source_id,
                "name": name,
                "brand": None,
                "categories": [],
                "serving_size_g": None,
            }
            write_jsonl_row(out, food_row)
            total_foods += 1

            for map_key, map_value in nutrient_map.items():
                if isinstance(map_value, dict):
                    calco_code = map_value["code"]
                    if map_value.get("combine"):
                        parts = map_key.split("+")
                        total = 0.0
                        found_any = False
                        for part in parts:
                            v = parse_amount(row[col_index.get(part)])
                            if v is not None:
                                total += v
                                found_any = True
                        if not found_any:
                            continue
                        amount = round(total, 6)
                    else:
                        scale = map_value.get("scale", 1.0)
                        v = parse_amount(row[col_index.get(map_key)])
                        if v is None:
                            continue
                        amount = round(v * scale, 6)
                else:
                    calco_code = map_value
                    v = parse_amount(row[col_index.get(map_key)])
                    if v is None:
                        continue
                    amount = v

                nutrient_row = {
                    "type": "nutrient",
                    "source": "INDB",
                    "source_id": source_id,
                    "nutrient_code": calco_code,
                    "amount_per_100g": amount,
                }
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

            energy_per_100g = parse_amount(row[col_index.get("energy_kcal")])
            energy_per_serving = parse_amount(
                row[col_index.get("unit_serving_energy_kcal")]
            )
            serving_grams: float | None = None
            if (
                energy_per_100g is not None
                and energy_per_100g > 0
                and energy_per_serving is not None
            ):
                serving_grams = round(energy_per_serving / energy_per_100g * 100, 2)

            serving_unit = str(
                row[col_index.get("servings_unit")] or "serving"
            ).strip()

            if serving_grams is not None and serving_grams > 0:
                serving_row = {
                    "type": "serving",
                    "source": "INDB",
                    "source_id": source_id,
                    "label": serving_unit,
                    "quantity": 1.0,
                    "unit": "serving",
                    "grams": serving_grams,
                }
                write_jsonl_row(out, serving_row)
                total_servings += 1

    wb.close()

    elapsed = time.time() - start
    log.info(
        "INDB 2024: %d foods, %d nutrients, %d servings -> %s (%.1fs)",
        total_foods,
        total_nutrients,
        total_servings,
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
    elif dataset == "indb":
        fetch_indb(cfg)
