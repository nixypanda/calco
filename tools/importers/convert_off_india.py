import csv
import gzip
import json
import os
import sys

MAPPING_PATH = os.path.join(os.path.dirname(__file__), "nutrient_mapping", "off_fields.json")
RAW_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw")
PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "processed")

REQUIRED_FIELDS = ["energy-kcal_100g", "proteins_100g", "carbohydrates_100g", "fat_100g"]


def parse_float(value):
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    try:
        v = float(value)
        return round(v, 6)
    except ValueError:
        return None


def countries_contain_india(countries_str):
    if not countries_str:
        return False
    return "india" in countries_str.lower()


def passes_filter(row):
    for field in REQUIRED_FIELDS:
        v = parse_float(row.get(field))
        if v is None or v <= 0:
            return False
    return True


def main():
    csv.field_size_limit(sys.maxsize)

    gz_path = os.path.join(RAW_DIR, "off_products.csv.gz")
    out_path = os.path.join(PROCESSED_DIR, "off_india.jsonl")

    if not os.path.exists(gz_path):
        print(f"ERROR: {gz_path} not found. Download it first.", file=sys.stderr)
        sys.exit(1)

    with open(MAPPING_PATH) as f:
        nutrient_map = json.load(f)

    os.makedirs(PROCESSED_DIR, exist_ok=True)

    total_scanned = 0
    total_kept = 0
    total_nutrients = 0

    with gzip.open(gz_path, "rt", encoding="utf-8", errors="replace") as gz_f, \
         open(out_path, "w") as out:

        reader = csv.DictReader(gz_f, delimiter="\t")

        for row in reader:
            total_scanned += 1

            if not countries_contain_india(row.get("countries_en", "")):
                continue
            if not passes_filter(row):
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
                "category": row.get("categories", "").strip() or None,
                "serving_size_g": None,
            }
            out.write(json.dumps(food_row, ensure_ascii=False) + "\n")
            total_kept += 1

            for csv_field, calco_code in nutrient_map.items():
                v = parse_float(row.get(csv_field))
                if v is None:
                    continue

                nutrient_row = {
                    "type": "nutrient",
                    "source": "OFF",
                    "source_id": source_id,
                    "nutrient_code": calco_code,
                    "amount_per_100g": v,
                }
                out.write(json.dumps(nutrient_row, ensure_ascii=False) + "\n")
                total_nutrients += 1

            if total_scanned % 500000 == 0:
                print(f"  scanned {total_scanned} rows, kept {total_kept} products...")

    print(f"OFF India: scanned {total_scanned}, kept {total_kept} products, {total_nutrients} nutrients -> {out_path}")


if __name__ == "__main__":
    main()
