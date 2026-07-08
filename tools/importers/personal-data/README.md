# CalCo Personal Data Import Tools

This directory centers on the structured MFP cleaning pipeline under `src/`
and the generated review artifacts under `data/`.

## MFP Nutrient Mapping Contract

The maintained MFP custom-food import path preserves every MFP nutrient value
that maps to an existing CalCo nutrient code.

Direct mappings:

| MFP column | CalCo nutrient code |
| --- | --- |
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

`%DV` conversions use current FDA Daily Values and are converted to absolute
units before storage:

| MFP column | CalCo nutrient code | Formula |
| --- | --- | --- |
| `vitamin_d_pct_daily_value` | `VITAMIN_D_UG` | `pct / 100 * 20` |
| `iron_pct_daily_value` | `IRON_MG` | `pct / 100 * 18` |
| `vitamin_a_pct_daily_value` | `VITAMIN_A_UG` | `pct / 100 * 900` |
| `vitamin_c_pct_daily_value` | `VITAMIN_C_MG` | `pct / 100 * 90` |

Conversion policy:

- `%DV` values are interpreted as percentages, not fractions.
- `15`, `15.0`, and `15%` all mean `15%`.
- blank nutrient fields are skipped
- explicit `0` values are preserved
- `VITAMIN_A_UG` is treated as compatible with imported values derived from
  `mcg RAE`

The four required macros remain a backend validation requirement, so
`create_foods.py` still backfills missing required macro nutrient codes with
`0` only when they are absent. That backfill is a safety net, not the intended
shape of the payload.

## Current Workflow

Run the cleaning pipeline:

```bash
cd tools/importers/personal-data/src
python3 clean.py --data-dir ../data
```

This produces:

- `data/step-0-out-merge_fixed_serving.csv`
- `data/step-1-out-normalize_units.csv`
- `data/step-2-out-scale_values.csv`
- `data/step-3-out-flag_pseudo_grams.csv`
- `data/step-3-review-pseudo-grams.csv`
- `data/step-4-out-check_macro_calories.csv`
- `data/step-4-review-macro-mismatch.csv`
- `data/step-5-out-fix_macro_mismatches.csv`
- `data/step-5-corrections.csv`
- `data/step-6-out-resolve_serving_modes.csv`
- `data/step-6-review-serving-modes.csv`
- `data/step-7-out-deduplicate.csv`
- `data/step-8-out-canonicalize_food_descriptions.csv`

Then generate the serving review:

```bash
cd tools/importers/personal-data
python3 generate_serving_review.py
```

This writes `data/step-9-out-serving-review.csv`.

Then generate the existing-food match review:

```bash
cd tools/importers/personal-data
python3 generate_food_match_review.py
```

This writes:

- `data/step-10-out-food-match-review.csv`
- `data/existing_food_matches.jsonl`

Current review artifacts produced during matching work:

- `data/step-10-match-report.md` — summary of the automated matcher run
- `data/step-10-macro-close-report.md` — alternate manual-review slice for
  weak-name but nutrition-close candidates
- `data/step-10-out-food-match-review-merged.csv` — merged review CSV with:
  - matcher auto-accepts
  - manually approved macro-close matches
- `data/existing_food_matches-merged.jsonl` — JSONL companion for the merged CSV

Current matcher handoff:

- Start from `docs/step-10-matcher-handoff.md`
- Treat `data/step-10-out-food-match-review-merged.csv` as the source of truth
  for accepted existing-food matches
- Do not overwrite the merged CSV blindly; generate a fresh review output and
  merge only accepted additions

Current finalized review state:

- `57` rows are matched to existing foods
- `225` rows were created as custom foods via `POST /api/foods/custom`
- all `282` rows now have `final_food_id`
- all `282` rows are marked `ready_for_log_import=true`

Next, use that finalized review CSV as the reference contract for historical
log import.

## Serving Review Output

`step-9-out-serving-review.csv` contains one row per distinct food with:

- `serving_mode`: `mass`, `volume`, or `serving_unit`
- `reference_basis`: `per_100g`, `per_100ml`, or `per_serving`
- `reference_*` nutrient columns on that basis for the full mapped nutrient set
- `example_value`, `example_unit`, `example_serving`
- `current_serving_grams`
- `corrected_serving_grams`
- `confidence`
- `notes`

The file is also the working review surface for later matching and import
decisions. After matching and creation, extend it with final reference columns
such as:

- `matched_food_id`
- `matched_food_name`
- `match_confidence`
- `match_basis`
- `match_notes`
- `created_food_id`
- `created_food_name`
- `final_food_id`
- `final_food_name`
- `final_action`
- `ready_for_log_import`

Rerunning `generate_serving_review.py` preserves existing values already entered
in `current_serving_grams`, `corrected_serving_grams`, `confidence`, and `notes`.

## Matching And Creation Workflow

After serving review is complete:

1. Search for strong matches in the CalCo DB for each reviewed food.
2. Reuse an existing DB food only when both name and nutrition are compatible.
3. Record accepted matches back into the review CSV with match metadata.
4. Generate JSONL only for foods that do not have a safe existing match.
5. Create those foods in the DB.
6. Write the created IDs and final canonical names back into the review CSV.
7. Treat the final CSV as the source of truth for historical diary import.

Keep separate machine-readable artifacts for the automated stages:

- `existing_food_matches.jsonl`
- `existing_food_matches-merged.jsonl`
- `foods_to_create.jsonl`

This keeps the CSV human-reviewable while giving downstream scripts stable
inputs.

Generate custom-food creation payloads:

```bash
cd tools/importers/personal-data
python3 generate_foods_to_create.py --selection all-unmatched
```

This writes `data/foods_to_create.jsonl` from
`data/step-10-out-food-match-review-merged.csv`.

Create unmatched foods through the user-facing custom-food API:

```bash
cd tools/importers/personal-data
.venv/bin/python create_foods.py \
  --api-url http://127.0.0.1:3001 \
  --visibility private \
  --session-token <calco_session_cookie_value>
```

Notes:

- the current backend dev default is `127.0.0.1:3001`
- this script makes one `POST /api/foods/custom` call per unmatched food
- it forwards the full mapped MFP nutrient set, including FDA `%DV`
  conversions, into the custom-food payload
- it writes `created_food_id`, `final_food_id`, `final_action`, and
  `ready_for_log_import` back into
  `data/step-10-out-food-match-review-merged.csv`
- for custom-food compatibility, the script backfills any missing required
  macro nutrient codes (`ENERGY_KCAL`, `PROTEIN_G`, `CARBS_G`, `FAT_G`) with
  `0`

## Current Step-10 Status

The current working review surface is:

- `data/step-10-out-food-match-review-merged.csv`

This file now includes:

- `57` matched-existing rows
- `225` created-new rows
- `282` finalized rows total

Recent manual/catalog follow-up has also added:

- barcode-backed `Ferrero Rocher`
- manual brand/variant mapping for `KitKat Share & Snap`
- manual Whole Truth mapping for `Double Cocoa`

The original matcher-only outputs are still preserved in:

- `data/step-10-out-food-match-review.csv`
- `data/existing_food_matches.jsonl`

The merged CSV should now be treated as the finalized source of truth for food
ID mapping unless a later review supersedes it.

## Current Creation Policy

The user set the following working decisions for downstream creation:

- do not spend more time searching external sources for branded products
- use `data/step-10-out-food-match-review-merged.csv` as the review surface
- create custom foods for every row that still does not have a `matched_food_id`
- `Apple` is already matched in the merged CSV/JSONL and should not be emitted
  in `foods_to_create.jsonl`
- do not overwrite the merged CSV blindly while doing this downstream work

`generate_foods_to_create.py` supports:

- `--selection approved-policy`
  - emits only the previously approved branded/raw-basic buckets
- `--selection all-unmatched`
  - emits every unresolved row in the merged CSV

Current working output:

- `data/foods_to_create.jsonl`
  - generated with `--selection all-unmatched`
  - contains `225` records, matching the `225` unmatched rows that were then
    created as custom foods
- `data/step-10-out-food-match-review-merged.csv`
  - now has `225` populated `created_food_id` values
  - now has `282` populated `final_food_id` values
  - now has `282` rows marked `ready_for_log_import=true`

## Historical Log Import

Use the API importer for diary history. It reads the finalized review CSV,
skips fingerprints that already exist for the target date, and posts each log
through the user-facing logs API.

Dry-run first:

```bash
python3 import_history.py \
  --api-url http://127.0.0.1:3001 \
  --history-csv data/step-8-out-canonicalize_food_descriptions.csv \
  --review-csv data/step-10-out-food-match-review-merged.csv \
  --session-token <calco_session_cookie_value> \
  --dry-run
```

Apply only after the dry-run counts are expected:

```bash
python3 import_history.py \
  --api-url http://127.0.0.1:3001 \
  --history-csv data/step-8-out-canonicalize_food_descriptions.csv \
  --review-csv data/step-10-out-food-match-review-merged.csv \
  --session-token <calco_session_cookie_value>
```

The old direct-SQL database repair path has been removed. Use
`../../verification/mfp/docs/mfp-import-flow-verification-plan.md` and
`../../verification/mfp/verify_custom_foods.py` for repeatable verification of
the API flow.

## Checks

Run from this directory:

```bash
python3 -m unittest discover -s src -p 'test_*.py'
```

If you are using the repo dev environment, the fuller checks from `AGENTS.md`
still apply:

```bash
nix develop ../../.. --command uv run ruff check .
nix develop ../../.. --command uv run ty check .
nix develop ../../.. --command uv run python -m unittest discover -s src -p 'test_*.py'
```
