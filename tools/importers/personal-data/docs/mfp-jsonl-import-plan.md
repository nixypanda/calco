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
basis and the current gram assumption used for downstream conversion. This CSV
becomes the central review artifact for food matching, creation, and historical
log import.

The maintained contract is that `reference_*` columns cover the full mapped MFP
nutrient set, not only the four required macros. `%DV` fields are converted to
absolute units using the FDA Daily Values documented below before they appear in
the review CSV.

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
| `reference_fiber_g` | Fiber on the reference basis |
| `reference_sugar_g` | Sugar on the reference basis |
| `reference_saturated_fat_g` | Saturated fat on the reference basis |
| `reference_trans_fat_g` | Trans fat on the reference basis |
| `reference_monounsaturated_fat_g` | Monounsaturated fat on the reference basis |
| `reference_polyunsaturated_fat_g` | Polyunsaturated fat on the reference basis |
| `reference_cholesterol_mg` | Cholesterol on the reference basis |
| `reference_sodium_mg` | Sodium on the reference basis |
| `reference_calcium_mg` | Calcium on the reference basis |
| `reference_potassium_mg` | Potassium on the reference basis |
| `reference_vitamin_d_ug` | Vitamin D on the reference basis |
| `reference_iron_mg` | Iron on the reference basis |
| `reference_vitamin_a_ug` | Vitamin A on the reference basis |
| `reference_vitamin_c_mg` | Vitamin C on the reference basis |
| `example_value` | Representative `value` from the CSV |
| `example_unit` | Representative `unit` from the CSV |
| `example_serving` | Representative `serving` from the CSV |
| `current_serving_grams` | Pipeline default or preserved prior review value |
| `corrected_serving_grams` | Reviewer-entered override |
| `confidence` | Confidence in the serving-to-grams estimate |
| `notes` | Reviewer notes |

#### Algorithm

1. Read CSV rows; filter `item_type = "Foods"`.
2. Group rows by `description`.
3. For each group, determine `serving_mode` from canonical units.
4. Compute a reference nutrient snapshot on the correct basis.
   Convert `%DV` source values to absolute units first, then scale them like
   the directly mapped nutrients.
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

### Step 11: `generate_food_match_review.py` — Match reviewed foods to existing DB foods

**Input:** `data/step-9-out-serving-review.csv`

**Output:**
- `data/step-10-out-food-match-review.csv`
- `data/existing_food_matches.jsonl`
- optional review-merged outputs after manual approval:
  - `data/step-10-out-food-match-review-merged.csv`
  - `data/existing_food_matches-merged.jsonl`

Search the CalCo DB for existing foods that are a very good match for the
reviewed foods. The purpose is to reuse an existing DB food only when both the
name and the nutrition profile are compatible.

#### Match acceptance rules

1. Exact or strongly normalized name match.
2. Compatible nutrient profile on the same basis.
3. Compatible serving semantics for the corrected serving-grams model.
4. If any of the above are weak or ambiguous, do not auto-reuse the DB food.

#### Output schema

`step-10-out-food-match-review.csv` should extend the reviewed serving CSV with:

| Column | Description |
|---|---|
| `matched_food_id` | Existing DB food ID if accepted |
| `matched_food_name` | Existing DB canonical name |
| `match_confidence` | Confidence in the DB match |
| `match_basis` | Why the match was accepted |
| `match_notes` | Manual notes on edge cases |

`existing_food_matches.jsonl` should contain one machine-readable record per
accepted existing-food match so downstream steps can run deterministically.

#### Current implemented behavior

The implemented matcher currently:

1. queries the local CalCo Postgres catalog directly via `psql`
2. searches global products only
3. compares `per_serving` foods on a derived per-100g basis using reviewed
   serving grams
4. writes top candidate diagnostics into `match_notes` for unmatched rows
5. supports a later manual merge step for nutrition-close approvals

#### Important constraint

Do not match by name alone. A food is only reusable when name and nutrition are
both close enough.

---

### Step 12: Manual review — Approve or reject DB food matches

**Input:** `data/step-10-out-food-match-review.csv`

**Output:** `data/step-10-out-food-match-review.csv` (edited in place)

The reviewer confirms which foods safely map to an existing DB food. Rejected
or unresolved rows move to the creation path.

#### Current practical workflow

In the current repo state, review can happen in two layers:

1. Review matcher auto-accepts and unmatched diagnostics in
   `step-10-out-food-match-review.csv`.
2. Review `step-10-macro-close-report.md` for weak-name but nutrition-close
   candidates and write approved rows into:
   - `step-10-out-food-match-review-merged.csv`
   - `existing_food_matches-merged.jsonl`

The merged CSV is the better starting point for downstream unmatched-food
creation, because it includes both automated and manually approved existing-food
matches.

---

### Step 13: `generate_foods_to_create.py` — Build JSONL for unmatched foods

**Input:** finalized step-10 review CSV

Preferred current input:

- `data/step-10-out-food-match-review-merged.csv`

**Output:** `data/foods_to_create.jsonl`

For rows without an accepted existing DB food match, emit canonical food
creation payloads. Each record should include the canonical name, nutrient
basis, corrected serving grams, and provenance back to the source description.

This file is the stable creation input and should be idempotent across reruns.

Recommended CLI:

```bash
python3 generate_foods_to_create.py --selection all-unmatched
```

Selection modes:

- `approved-policy` — emit only the explicit approved-policy custom-food set
- `all-unmatched` — emit every row whose `matched_food_id` is still empty in
  the finalized review CSV

---

### Step 14: `create_foods.py` — Create unmatched foods in the DB

**Input:** `data/foods_to_create.jsonl`

**Output:**
- DB food records
- updated `data/step-10-out-food-match-review-merged.csv`

Create the unmatched foods in the DB, then write the returned IDs and final
canonical names back into the CSV.

#### Current implemented behavior

The maintained script is now:

- `create_foods.py`

The current practical mode is:

- use the user-facing custom-food API only
- call `POST /api/foods/custom` once per row in `data/foods_to_create.jsonl`
- authenticate with a `calco_session` cookie value
- target the running backend at `http://127.0.0.1:3001` in the current local
  dev setup
- forward the full mapped nutrient set from `foods_to_create.jsonl`, including
  nutrients derived from `%DV` source fields

For compatibility with the custom-food API, the script backfills any missing
required macro nutrient codes with `0`:

- `ENERGY_KCAL`
- `PROTEIN_G`
- `CARBS_G`
- `FAT_G`

The latest completed run created `225` custom foods and updated
`data/step-10-out-food-match-review-merged.csv` so that:

- `57` rows are `matched_existing`
- `225` rows are `created_new`
- all `282` rows have `final_food_id`
- all `282` rows have `ready_for_log_import=true`

After this step, the CSV should carry final reference columns such as:

| Column | Description |
|---|---|
| `created_food_id` | Newly created DB food ID |
| `created_food_name` | Newly created canonical DB food name |
| `final_food_id` | Final DB food ID to use for logs |
| `final_food_name` | Final DB food name to use for logs |
| `final_action` | `matched_existing` or `created_new` |
| `ready_for_log_import` | Whether the row is finalized |

The final CSV becomes the source-of-truth contract for historical log import.

---

### Step 15: `apply_serving_review.py` — Apply corrected servings

**Input:**
- `data/step-8-out-canonicalize_food_descriptions.csv`
- finalized reviewed CSV with corrected servings and final food IDs

**Output:** `data/step-11-out-serving-corrected.csv`

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

### Step 16: `csv_to_jsonl.py` — Convert unmatched foods to JSONL

**Input:**
- `data/step-11-out-serving-corrected.csv`
- finalized reviewed CSV

**Output:** `data/step-12-foods.jsonl`

One JSON line per unique food description, shaped as a
`POST /api/foods/custom` payload. In the current plan, this is only needed for
the unmatched-food creation path and should be equivalent to
`foods_to_create.jsonl` or be generated directly from it.

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
    {"code": "CARBS_G",     "amount_per_100g": 10.18, "source": "mfp", "confidence": "derived"},
    {"code": "FIBER_G",     "amount_per_100g": 3.10,  "source": "mfp", "confidence": "derived"},
    {"code": "SODIUM_MG",   "amount_per_100g": 222.0, "source": "mfp", "confidence": "derived"},
    {"code": "IRON_MG",     "amount_per_100g": 2.70,  "source": "mfp", "confidence": "derived"}
  ],
  "servings": [
    {"label": "1 g", "quantity": 1, "unit": "g", "grams": 1}
  ]
}
```

#### Algorithm

1. Read the serving-corrected CSV; filter `item_type = "Foods"`.
2. Group rows by `description`.
3. For each group, look up the final CSV decision.
4. If `final_action = matched_existing` → don't emit JSONL.
5. If `final_action = created_new`:
   - Pick a representative row.
   - Compute per-100g nutrients:
     - **Mass mode:** `per_100g = nutrient_amount × 100 / value`
     - **Serving_unit mode:** `per_100g = nutrient_amount × 100 / (value × serving_grams)`
   - Write JSONL.

#### CSV → Nutrient Mapping

| CSV column | Nutrient code |
|---|---|
| `calories` | `ENERGY_KCAL` |
| `protein_g` | `PROTEIN_G` |
| `carbs_g` | `CARBS_G` |
| `fat_g` | `FAT_G` |
| `fiber_g` | `FIBER_G` |
| `sugar_g` | `SUGAR_G` |
| `saturated_fat_g` | `SATURATED_FAT_G` |
| `trans_fat_g` | `TRANS_FAT_G` |
| `monounsaturated_fat_g` | `MONOUNSATURATED_FAT_G` |
| `polyunsaturated_fat_g` | `POLYUNSATURATED_FAT_G` |
| `cholesterol_mg` | `CHOLESTEROL_MG` |
| `sodium_mg` | `SODIUM_MG` |
| `calcium_mg` | `CALCIUM_MG` |
| `potassium_mg` | `POTASSIUM_MG` |
| `vitamin_d_pct_daily_value` | `VITAMIN_D_UG` |
| `iron_pct_daily_value` | `IRON_MG` |
| `vitamin_a_pct_daily_value` | `VITAMIN_A_UG` |
| `vitamin_c_pct_daily_value` | `VITAMIN_C_MG` |

Unsupported columns remain limited to fields with no current CalCo nutrient
code or no approved conversion policy, such as `added_sugar_g` and
`sugar_alcohols_g`.

#### FDA %DV Conversion Policy

Converted `%DV` fields use current FDA Daily Values:

| CSV column | Daily Value | Stored formula |
|---|---|---|
| `vitamin_d_pct_daily_value` | `20 mcg` | `pct / 100 * 20` |
| `iron_pct_daily_value` | `18 mg` | `pct / 100 * 18` |
| `vitamin_a_pct_daily_value` | `900 mcg RAE` | `pct / 100 * 900` |
| `vitamin_c_pct_daily_value` | `90 mg` | `pct / 100 * 90` |

Rules:

- `%DV` inputs are percentages, not fractions
- `15`, `15.0`, and `15%` are interpreted identically
- blank values are skipped
- explicit `0` values are preserved

---

### Step 17: `upload_foods.py` — Upload created foods to CalCo

**Input:**
- `data/step-12-foods.jsonl`
- finalized reviewed CSV

**Output:** `data/mfp-food-map.json`

For each distinct food:
- If `final_action = matched_existing`: record `final_food_id` from the review
  CSV in the food map without creating a new food.
- If `final_action = created_new`: call `POST /api/foods/custom` with the JSONL
  payload only if the DB ID has not already been written back into the CSV.
- Otherwise: skip.

In the current repo state, this step is effectively superseded by
`create_foods.py`, which already writes the created IDs back into
`data/step-10-out-food-match-review-merged.csv`.

Writes `mfp-food-map.json` mapping `description → { product_id, name,
serving_mode }`.

---

### Step 18: `import_history.py` — Import diary logs

**Input:**
- `data/step-8-out-canonicalize_food_descriptions.csv` (original rows)
- finalized reviewed CSV or `data/mfp-food-map.json`

For each CSV row where `item_type == "Foods"`:
1. Look up the final DB food ID by `description`.
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

Historical import stays product-id plus quantity based. The maintained path is
the user-facing API importer in `import_history.py`, which computes stable MFP
fingerprints, skips already imported rows, and posts logs through `/api/logs`.
Custom-food nutrient equivalence is verified separately with
`tools/verification/mfp/verify_custom_foods.py`.

The old direct-SQL repair workflow has been removed. Re-run the isolated API
verification documented in
`tools/verification/mfp/docs/mfp-import-flow-verification-plan.md` when checking
future importer changes or another database/user.

---

## File Layout

```
tools/importers/personal-data/
├── data/
│   ├── step-8-out-canonicalize_food_descriptions.csv (input)
│   ├── step-9-out-serving-review.csv                (step 9, then edited by user)
│   ├── step-10-out-food-match-review.csv           (matcher output)
│   ├── step-10-out-food-match-review-merged.csv    (matcher + manual approvals)
│   ├── existing_food_matches.jsonl                 (matcher JSONL)
│   ├── existing_food_matches-merged.jsonl          (merged JSONL)
│   ├── step-10-match-report.md                     (matcher summary)
│   ├── step-10-macro-close-report.md               (manual review slice)
│   ├── foods_to_create.jsonl                       (custom-food creation input)
│   ├── step-11-out-serving-corrected.csv           (future step)
│   ├── step-12-foods.jsonl                         (future step)
│   ├── mfp-food-map.json                           (future step)
│   └── mfp-history-mismatches.csv                  (future step)
├── docs/
│   ├── mfp-jsonl-import-plan.md
│   └── step-10-matcher-handoff.md
├── generate_serving_review.py                     (step 9)
├── generate_food_match_review.py                  (step 11)
├── create_foods.py                                (step 14)
├── apply_serving_review.py                        (future step)
├── csv_to_jsonl.py                                (future step)
├── upload_foods.py                                (future step)
└── import_history.py                              (future step)

tools/verification/mfp/
├── docs/
│   ├── mfp-import-flow-verification-plan.md
│   └── mfp-verify-cleanup.sql
└── verify_custom_foods.py
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
