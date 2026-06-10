# MFP CSV → JSONL Import Plan

## Purpose

Convert `data/step-8-out-canonicalize_food_descriptions.csv` into JSONL for upload into
CalCo via the user-facing Custom Foods API (`POST /api/foods/custom`), then
import diary history.

## Overview

The step-7 CSV already has scaled values (step 2 already applied
`value × serving_number`). We use them as-is.

All steps generate CSVs following the existing pipeline convention
(`step-N-out-NAME.csv`) so each transformation is reviewable.

---

## Pipeline Steps

### Step 9: `generate_serving_review.py` — Serving review CSV

**Input:** `data/step-8-out-canonicalize_food_descriptions.csv`

**Output:** `data/step-9-out-serving-review.csv`

Generate a CSV with one row per distinct food showing the reference nutrient
basis and the current gram assumption used for downstream conversion.

Reruns preserve any existing edits already present in
`data/step-9-out-serving-review.csv`.

#### Output schema

| Column | Description |
|---|---|
| `description` | Distinct food name |
| `row_count` | Number of CSV rows for this food |
| `serving_mode` | `mass`, `volume`, or `serving_unit` |
| `reference_basis` | `per_100g`, `per_100ml`, or `per_serving` |
| `reference_calories` | Energy on the reference basis |
| `reference_protein_g` | Protein on the reference basis |
| `reference_carbs_g` | Carbs on the reference basis |
| `reference_fat_g` | Fat on the reference basis |
| `example_value` | Representative `value` from the CSV |
| `example_unit` | Representative `unit` from the CSV |
| `example_serving` | Representative `serving` from the CSV |
| `current_serving_grams` | Pipeline default or preserved prior review value |
| `corrected_serving_grams` | Reviewer-entered override |
| `notes` | Reviewer notes |

#### Algorithm

1. Read CSV rows; filter `item_type = "Foods"`.
2. Group rows by `description`.
3. For each group, determine `serving_mode` from canonical units.
4. Compute a reference nutrient snapshot on the correct basis.
5. Preserve prior review edits when the output file already exists.
6. Write one CSV row per distinct food.

---

### Step 10: Manual review — User edits serving review CSV

**Input:** `data/step-9-out-serving-review.csv`

**Output:** `data/step-9-out-serving-review.csv` (edited in place)

User fills in `corrected_serving_grams` where needed:

- **Mass mode foods:** usually leave as-is; `current_serving_grams` should stay `100`.
- **Volume mode foods:** add a gram equivalent only if the downstream importer
  needs mass conversion rather than volume-native handling.
- **Serving_unit mode foods:** enter grams per 1 serving
  (e.g. `Banana` → `118`, `Boiled Egg` → `50`, `Bread` → `30`).

Also consult `step-6-review-serving-modes.csv` which already flags foods
with ambiguous serving modes.

---

### Step 11: `apply_serving_review.py` — Apply corrected servings

**Input:**
- `data/step-8-out-canonicalize_food_descriptions.csv`
- `data/step-9-out-serving-review.csv`

**Output:** `data/step-10-out-serving-corrected.csv`

Apply the corrected `serving_grams` to the original CSV rows.

#### Algorithm

For each row in the input CSV where `item_type = "Foods"`:
1. Look up `corrected_serving_grams` by `description` in the review CSV.
2. If found for mass-mode: add column `serving_grams` = corrected value
   (retain original `value` and `unit` as-is).
3. If found for serving_unit-mode: add column `serving_grams` = corrected
   value (used later for per-100g computation).
4. If not in review file: add `serving_grams` = 100 (default).
5. Preserve all original columns + new `serving_grams` column.

This CSV still has the same row-level structure as the input — it just adds
a `serving_grams` column for downstream use.

---

### Step 12: `generate_match_review.py` — Search for pre-existing foods

**Input:** `data/step-10-out-serving-corrected.csv`

**Output:** `data/step-11-out-match-review.csv`

For each distinct food, search the CalCo catalog via
`GET /api/foods/search?q=<name>`. If a close match is found, suggest
using the existing product instead of creating a custom food.

#### Matching criteria

1. Fuzzy name score ≥ 92 (`token_set_ratio`).
2. Energy compatibility: `|example_cals_per_100g - matched_cals_per_100g| <= 30`.

#### Output schema

| Column | Description |
|---|---|
| `description` | Distinct food name |
| `serving_mode` | `mass`, `serving_unit`, or `manual` |
| `row_count` | Number of CSV rows for this food |
| `example_calories` | Representative calories from the row |
| `serving_grams` | Corrected serving grams from step 10 |
| `suggested_action` | `match` if a good match found, `create` otherwise |
| `matched_product_id` | CalCo product UUID if matched |
| `matched_product_name` | CalCo product name if matched |
| `match_score` | Fuzzy match score (0–100) |
| `approved` | Empty — user fills in `yes` or `no` |
| `notes` | Empty — user adds notes |

---

### Step 13: Manual review — User approves matches

**Input:** `data/step-11-out-match-review.csv`

**Output:** `data/step-11-out-match-review.csv` (edited in place)

User sets `approved` for each row:
- `yes` + `suggested_action = match` → use existing product, skip creation
- `yes` + `suggested_action = create` → create custom food
- `no` → skip this food entirely

---

### Step 14: `csv_to_jsonl.py` — Convert to JSONL

**Input:**
- `data/step-10-out-serving-corrected.csv` (source data with serving grams)
- `data/step-11-out-match-review.csv` (match decisions)

**Output:** `data/step-13-foods.jsonl`

One JSON line per unique food description, shaped as a
`POST /api/foods/custom` payload. Skips foods where `approved = no`.

```json
{
  "name": "Kala Chana Masala",
  "brand": "MyFitnessPal",
  "categories": ["mfp-import"],
  "serving_size_g": 100,
  "default_quantity": 1,
  "default_unit": "g",
  "nutrients": [
    {"code": "ENERGY_KCAL", "amount_per_100g": 76.99, "source": "mfp", "confidence": "derived"},
    {"code": "PROTEIN_G",   "amount_per_100g": 2.66,  "source": "mfp", "confidence": "derived"},
    {"code": "FAT_G",       "amount_per_100g": 3.54,  "source": "mfp", "confidence": "derived"},
    {"code": "CARBS_G",     "amount_per_100g": 10.18, "source": "mfp", "confidence": "derived"}
  ],
  "servings": [
    {"label": "1 g", "quantity": 1, "unit": "g", "grams": 1}
  ]
}
```

#### Algorithm

1. Read the serving-corrected CSV; filter `item_type = "Foods"`.
2. Group rows by `description`.
3. For each group, look up the match review decision.
4. If `approved = no` → skip.
5. If `approved = yes` and `suggested_action = match` → don't emit JSONL
   (will be handled by product ID reference later).
6. If `approved = yes` and `suggested_action = create`:
   - Pick a representative row.
   - Compute per-100g nutrients:
     - **Mass mode:** `per_100g = nutrient_amount × 100 / value`
     - **Serving_unit mode:** `per_100g = nutrient_amount × 100 / (value × serving_grams)`
   - Write JSONL.

#### CSV → Nutrient Mapping

| CSV column | Nutrient code |
|---|---|
| `calories` | `ENERGY_KCAL` |
| `fat_g` | `FAT_G` |
| `saturated_fat_g` | `SATURATED_FAT_G` |
| `trans_fat_g` | `TRANS_FAT_G` |
| `polyunsaturated_fat_g` | `POLYUNSATURATED_FAT_G` |
| `monounsaturated_fat_g` | `MONOUNSATURATED_FAT_G` |
| `cholesterol_mg` | `CHOLESTEROL_MG` |
| `sodium_mg` | `SODIUM_MG` |
| `carbs_g` | `CARBS_G` |
| `fiber_g` | `FIBER_G` |
| `sugar_g` | `SUGAR_G` |
| `protein_g` | `PROTEIN_G` |
| `calcium_mg` | `CALCIUM_MG` |
| `potassium_mg` | `POTASSIUM_MG` |

Unsupported columns (`added_sugar_g`, `sugar_alcohols_g`,
`vitamin_d_pct_daily_value`, `iron_pct_daily_value`,
`vitamin_a_pct_daily_value`, `vitamin_c_pct_daily_value`) are skipped.

---

### Step 14: `upload_foods.py` — Upload to CalCo

**Input:**
- `data/step-13-foods.jsonl`
- `data/step-11-out-match-review.csv` (for match lookups)

**Output:** `data/mfp-food-map.json`

For each distinct food:
- If `approved = yes` and `suggested_action = match`: record `product_id`
  from the review CSV in the food map (no API call).
- If `approved = yes` and `suggested_action = create`: call
  `POST /api/foods/custom` with the JSONL payload, record returned
  `product_id` in the food map.
- If `approved = no`: skip.

Writes `mfp-food-map.json` mapping `description → { product_id, name,
serving_mode }`.

---

### Step 15: `import_history.py` — Import diary logs

**Input:**
- `data/step-8-out-canonicalize_food_descriptions.csv` (original rows)
- `data/mfp-food-map.json` (product lookup)

For each CSV row where `item_type == "Foods"`:
1. Look up `product_id` by `description` in the food map.
2. If not found → skip (log warning).
3. Compute fingerprint:
   `sha256(date + description + value + unit + nutrients)`.
4. Check existing logs for that fingerprint (via
   `GET /api/logs?from=date&to=date`).
5. If duplicate → skip.
6. Otherwise, POST to `/api/logs`:

```json
{
  "logged_at": "2024-03-18T12:00:00Z",
  "meal_slot": "Lunch",
  "item": {"type": "product", "id": "product_id"},
  "quantity": {"amount": "2", "unit": "egg"},
  "notes": "mfp_row=<fingerprint> imported_from=myfitnesspal"
}
```

7. Report nutrient mismatches to `mfp-history-mismatches.csv`.

---

## File Layout

```
tools/importers/personal-data/
├── data/
│   ├── step-8-out-canonicalize_food_descriptions.csv (input)
│   ├── step-9-out-serving-review.csv                (step 9, then edited by user)
│   ├── step-10-out-serving-corrected.csv      (step 10)
│   ├── step-11-out-match-review.csv          (step 11, then edited by user)
│   ├── step-13-foods.jsonl                   (step 13)
│   ├── mfp-food-map.json                     (step 14)
│   └── mfp-history-mismatches.csv            (step 15)
├── docs/
│   └── mfp-jsonl-import-plan.md
├── csv_to_jsonl.py                           (step 13)
├── generate_serving_review.py                (step 8)
├── apply_serving_review.py                   (step 10)
├── generate_match_review.py                  (step 11)
├── upload_foods.py                           (step 14)
└── import_history.py                         (step 15)
```

## Dependencies

- Python 3.12+ (same as existing project)
- `requests` for API calls
- `rapidfuzz` for fuzzy matching (already in `pyproject.toml`)

## Output Convention

All step outputs follow the existing pipeline naming:
`step-N-out-NAME.csv` for CSVs, with JSONL files using a `.jsonl`
extension instead. The input for each step is the previous step's output
(or the review file where applicable).
