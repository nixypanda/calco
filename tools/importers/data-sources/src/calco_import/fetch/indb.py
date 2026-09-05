import json
import logging
import os
import time

import openpyxl

from calco_import.fetch import MAPPING_DIR
from calco_import.fetch._download import download_file
from calco_import.util import parse_amount, write_jsonl_row

log = logging.getLogger(__name__)

INDB_XLSX_URL = (
    "https://www.anuvaad.org.in/wp-content/uploads/2020/07/Anuvaad_INDB_2024.11.xlsx"
)
INDB_XLSX_FILENAME = "Anuvaad_INDB_2024.11.xlsx"
INDB_PROCESSED_FILENAME = "indb_2024.jsonl"


def _build_indb_food_row(source_id: str, name: str) -> dict:
    return {
        "type": "food",
        "source": "INDB",
        "source_id": source_id,
        "name": name,
        "brand": None,
        "categories": [],
    }


def _extract_indb_nutrient(
    row: tuple,
    col_index: dict[str, int],
    map_key: str,
    map_value: dict | str,
) -> tuple[str, float] | None:
    if isinstance(map_value, dict):
        calco_code = map_value["code"]
        if map_value.get("combine"):
            parts = map_key.split("+")
            total = 0.0
            found_any = False
            for part in parts:
                part_idx = col_index.get(part)
                v = parse_amount(row[part_idx] if part_idx is not None else None)
                if v is not None:
                    total += v
                    found_any = True
            if not found_any:
                return None
            amount = round(total, 6)
        else:
            scale = map_value.get("scale", 1.0)
            map_idx = col_index.get(map_key)
            v = parse_amount(row[map_idx] if map_idx is not None else None)
            if v is None:
                return None
            amount = round(v * scale, 6)
    else:
        calco_code = map_value
        map_idx = col_index.get(map_key)
        v = parse_amount(row[map_idx] if map_idx is not None else None)
        if v is None:
            return None
        amount = v
    return calco_code, amount


def _build_indb_serving_row(
    row: tuple,
    col_index: dict[str, int],
    source_id: str,
) -> dict | None:
    energy_idx = col_index.get("energy_kcal")
    serving_energy_idx = col_index.get("unit_serving_energy_kcal")
    energy_per_100g = parse_amount(row[energy_idx] if energy_idx is not None else None)
    energy_per_serving = parse_amount(
        row[serving_energy_idx] if serving_energy_idx is not None else None
    )
    if energy_per_100g is None or energy_per_100g <= 0 or energy_per_serving is None:
        return None
    serving_grams = round(energy_per_serving / energy_per_100g * 100, 2)
    if serving_grams <= 0:
        return None

    servings_unit_idx = col_index.get("servings_unit")
    serving_unit = str(
        row[servings_unit_idx] if servings_unit_idx is not None else "serving"
    ).strip()
    return {
        "type": "serving",
        "source": "INDB",
        "source_id": source_id,
        "label": serving_unit,
        "quantity": 1.0,
        "unit": "serving",
        "grams": serving_grams,
    }


def fetch_indb(data_dir: str) -> None:
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

            food_row = _build_indb_food_row(source_id, name)
            write_jsonl_row(out, food_row)
            total_foods += 1

            for map_key, map_value in nutrient_map.items():
                result = _extract_indb_nutrient(row, col_index, map_key, map_value)
                if result is None:
                    continue
                calco_code, amount = result
                nutrient_row = {
                    "type": "nutrient",
                    "source": "INDB",
                    "source_id": source_id,
                    "nutrient_code": calco_code,
                    "amount_per_100g": amount,
                }
                write_jsonl_row(out, nutrient_row)
                total_nutrients += 1

            serving_row = _build_indb_serving_row(row, col_index, source_id)
            if serving_row is not None:
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
