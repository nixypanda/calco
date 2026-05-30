import json
import zipfile
import os
import sys

MAPPING_PATH = os.path.join(os.path.dirname(__file__), "nutrient_mapping", "usda_sr_codes.json")
RAW_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw")
PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "processed")


def parse_amount(value):
    try:
        return round(float(value), 6)
    except (ValueError, TypeError):
        return None


def main():
    zip_path = os.path.join(RAW_DIR, "usda_sr_legacy.zip")
    out_path = os.path.join(PROCESSED_DIR, "usda_sr_legacy.jsonl")

    if not os.path.exists(zip_path):
        print(f"ERROR: {zip_path} not found. Download it first.", file=sys.stderr)
        sys.exit(1)

    with open(MAPPING_PATH) as f:
        nutrient_map = json.load(f)

    os.makedirs(PROCESSED_DIR, exist_ok=True)

    total_foods = 0
    total_nutrients = 0

    with zipfile.ZipFile(zip_path, "r") as z:
        json_files = [n for n in z.namelist() if n.endswith(".json")]
        if not json_files:
            print("ERROR: No JSON file found in zip archive.", file=sys.stderr)
            sys.exit(1)

        with z.open(json_files[0]) as f:
            data = json.load(f)

    if isinstance(data, dict):
        foods = data.get("FoundationFoods", data.get("SRLegacyFoods", data.get("Foods", [])))
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
                "category": str(category) if category else None,
                "serving_size_g": serving_size,
            }
            out.write(json.dumps(food_row, ensure_ascii=False) + "\n")
            total_foods += 1

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
                out.write(json.dumps(nutrient_row, ensure_ascii=False) + "\n")
                total_nutrients += 1

    print(f"USDA SR: {total_foods} foods, {total_nutrients} nutrients -> {out_path}")


if __name__ == "__main__":
    main()
