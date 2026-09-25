import csv
import json
import logging
import os
import shlex
import subprocess
import sys
import time
from collections.abc import Iterator
from typing import NamedTuple

from calco_import.fetch._download import download_file
from calco_import.paths import MAPPING_DIR
from calco_import.util import parse_amount, write_jsonl_row

log = logging.getLogger(__name__)

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
GTIN_8_LENGTH = 8
GTIN_13_LENGTH = 13
GTIN_14_LENGTH = 14
GS1_INDIA_PREFIX = "890"


class OffIndices(NamedTuple):
    code: int
    product: int
    brands: int
    categories: int
    countries_tags: int
    serving_qty: int
    serving_size: int


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


def has_gs1_india_prefix(code: str) -> bool:
    if not code.isdigit():
        return False
    if len(code) == GTIN_14_LENGTH:
        return code[1:4] == GS1_INDIA_PREFIX
    return len(code) in (GTIN_8_LENGTH, GTIN_13_LENGTH) and code.startswith(
        GS1_INDIA_PREFIX
    )


def _parse_off_header(header: list[str]) -> tuple[OffIndices, dict[str, int]]:
    idx_countries_tags = header.index("countries_tags")
    idx_code = header.index("code")
    idx_product = header.index("product_name")
    idx_brands = header.index("brands")
    idx_categories = header.index("categories")
    idx_serving_qty = header.index("serving_quantity")
    idx_serving_size = header.index("serving_size")

    indices = OffIndices(
        code=idx_code,
        product=idx_product,
        brands=idx_brands,
        categories=idx_categories,
        countries_tags=idx_countries_tags,
        serving_qty=idx_serving_qty,
        serving_size=idx_serving_size,
    )

    mapping_path = f"{MAPPING_DIR}/off_fields.json"
    with open(mapping_path) as f:
        nutrient_map = json.load(f)

    nutrient_indices = {
        calco_code: header.index(csv_field)
        for csv_field, calco_code in nutrient_map.items()
    }

    return indices, nutrient_indices


def _keep_off_row(
    row: list[str],
    indices: OffIndices,
    required_indices: list[int],
) -> bool:
    country_tags = {
        tag.strip().lower() for tag in row[indices.countries_tags].split(",")
    }
    code = row[indices.code].strip()
    if "en:india" not in country_tags and not has_gs1_india_prefix(code):
        return False
    for idx in required_indices:
        v = parse_amount(row[idx])
        if v is None or v <= 0:
            return False
    return True


def _build_off_food_row(
    row: list[str],
    indices: OffIndices,
) -> dict:
    code = row[indices.code].strip()
    return {
        "type": "food",
        "source": "OFF",
        "source_id": code,
        "barcode": code,
        "name": row[indices.product].strip() or None,
        "brand": row[indices.brands].strip() or None,
        "categories": categories_from_csv(row[indices.categories]),
    }


def _build_off_serving_row(
    row: list[str],
    indices: OffIndices,
    source_id: str,
) -> dict | None:
    serving_grams = parse_amount(row[indices.serving_qty])
    if serving_grams is None or serving_grams <= 0:
        return None
    return {
        "type": "serving",
        "source": "OFF",
        "source_id": source_id,
        "unit": "serving",
        "grams_per_unit": serving_grams,
    }


def _build_off_nutrient_rows(
    row: list[str],
    nutrient_indices: dict[str, int],
    source_id: str,
) -> Iterator[dict]:
    for calco_code, col_idx in nutrient_indices.items():
        v = parse_amount(row[col_idx])
        if v is None:
            continue
        amount = round(v * scale_off_code(calco_code), 6)
        yield {
            "type": "nutrient",
            "source": "OFF",
            "source_id": source_id,
            "nutrient_code": calco_code,
            "amount_per_100g": amount,
        }


def fetch_off(data_dir: str) -> None:
    raw_dir = os.path.join(data_dir, "raw")
    processed_dir = os.path.join(data_dir, "processed")
    gz_path = os.path.join(raw_dir, "off_products.csv.gz")
    out_path = os.path.join(processed_dir, "off_india.jsonl")

    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(processed_dir, exist_ok=True)

    if not os.path.exists(gz_path):
        download_file(OFF_GZ_URL, gz_path)

    # Use zcat + grep instead of Python's csv.DictReader or csv.reader on the
    # raw gz. The full OFF dump is 1.2 GB compressed; reading it entirely into
    # Python would be slow. zcat streams decompressed data through grep which
    # filters to exact India-tag candidates and 890-prefix candidates in C
    # before Python ever sees them. Python then validates the country tag,
    # barcode prefix, and required nutrients.
    pipe_cmd = (
        f"zcat {shlex.quote(gz_path)}"
        ' | { read -r header; echo "$header"; grep -Ei "(en:india|^[0-9]?890)"; }'
    )

    proc = subprocess.Popen(
        ["bash", "-c", pipe_cmd],
        stdout=subprocess.PIPE,
        text=True,
    )

    csv.field_size_limit(sys.maxsize)
    assert proc.stdout is not None
    reader = csv.reader(proc.stdout, delimiter="\t")
    header = next(reader)

    indices, nutrient_indices = _parse_off_header(header)

    required_indices = [header.index(f) for f in REQUIRED_OFF_FIELDS]

    start = time.time()
    total_kept = 0
    total_nutrients = 0
    total_servings = 0

    with open(out_path, "w") as out:
        for row in reader:
            if not _keep_off_row(row, indices, required_indices):
                continue

            code = row[indices.code].strip()
            if not code:
                continue

            food_row = _build_off_food_row(row, indices)
            write_jsonl_row(out, food_row)
            total_kept += 1

            serving_row = _build_off_serving_row(row, indices, code)
            if serving_row is not None:
                write_jsonl_row(out, serving_row)
                total_servings += 1

            for nutrient_row in _build_off_nutrient_rows(row, nutrient_indices, code):
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

    if proc.stdout is not None:
        proc.stdout.close()
    ret = proc.wait()
    if ret not in (0, 1):
        log.warning("OFF filtering pipeline exited with code %d", ret)

    elapsed = time.time() - start
    log.info(
        "OFF India: kept %d products, %d nutrients, %d servings -> %s (%.1fs)",
        total_kept,
        total_nutrients,
        total_servings,
        out_path,
        elapsed,
    )
