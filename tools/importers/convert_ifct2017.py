import csv
import json
import os
import sys
import re

MAPPING_PATH = os.path.join(os.path.dirname(__file__), "nutrient_mapping", "ifct2017_codes.json")
RAW_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw")
PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "processed")

FOOD_GROUP_MAP = {
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

RE_VALUE_ERROR = re.compile(r"^([\d.]+)\s*±")


def categories_from_value(value):
    if not value:
        return []
    normalized = value.strip().lower()
    return [normalized] if normalized else []


def parse_ifct_value(raw):
    if raw is None:
        return None
    raw = raw.strip()
    if not raw or raw in ("-", "NA", "n/a", ""):
        return None

    m = RE_VALUE_ERROR.match(raw)
    if m:
        raw = m.group(1)

    try:
        v = float(raw)
        return round(v, 6)
    except ValueError:
        return None


def main():
    csv_path = os.path.join(RAW_DIR, "ifct2017_compositions.csv")
    out_path = os.path.join(PROCESSED_DIR, "ifct2017.jsonl")

    if not os.path.exists(csv_path):
        print(f"ERROR: {csv_path} not found.", file=sys.stderr)
        sys.exit(1)

    with open(MAPPING_PATH) as f:
        nutrient_map = json.load(f)

    os.makedirs(PROCESSED_DIR, exist_ok=True)

    total_foods = 0
    total_nutrients = 0

    with open(csv_path, encoding="utf-8") as csv_f, \
         open(out_path, "w") as out:

        reader = csv.DictReader(csv_f)

        for row in reader:
            code = row.get("code", "").strip()
            name = row.get("name", "").strip()
            if not code or not name:
                continue

            grup = row.get("grup", "").strip()
            category = FOOD_GROUP_MAP.get(grup, grup.lower().replace(" ", "-") if grup else None)

            food_row = {
                "type": "food",
                "source": "IFCT",
                "source_id": code,
                "name": name,
                "brand": None,
                "categories": categories_from_value(category),
                "serving_size_g": None,
            }
            out.write(json.dumps(food_row, ensure_ascii=False) + "\n")
            total_foods += 1

            for ifct_code, calco_code in nutrient_map.items():
                v = parse_ifct_value(row.get(ifct_code))
                if v is None:
                    continue

                nutrient_row = {
                    "type": "nutrient",
                    "source": "IFCT",
                    "source_id": code,
                    "nutrient_code": calco_code,
                    "amount_per_100g": v,
                }
                out.write(json.dumps(nutrient_row, ensure_ascii=False) + "\n")
                total_nutrients += 1

    print(f"IFCT 2017: {total_foods} foods, {total_nutrients} nutrients -> {out_path}")


if __name__ == "__main__":
    main()
