# Personal Data Importer

Tools for importing private user nutrition data into CalCo. The maintained
workflow is the MyFitnessPal pipeline, which cleans raw export CSVs, prepares
human-reviewable food mapping artifacts, creates missing private foods, and
imports diary history through user-facing APIs.

## Safety

Files in `data/` may contain private diary history, food names, and account
export details. Do not commit raw exports or local review outputs unless they
are intentionally tracked fixtures. Remove one-off markdown reports when they
are no longer part of the active workflow.

## Inputs

The MFP workflow expects raw source files under `data/`:

| File | Purpose |
| --- | --- |
| `mfp-data.csv` | MFP privacy export with diary rows and nutrient columns. |
| `mfp-data-fixed.csv` | Supplemental MFP export with meal and serving fields. |

The cleaning pipeline preserves MFP's CSV shape: a title row followed by a CSV
header row and data rows.

## Workflow

Run commands from `tools/importers/personal-data`.

### 1. Clean the raw export

```bash
uv run python src/clean.py --data-dir data
```

This writes numbered CSV outputs from `step-0` through `step-8`. Each step fixes
one class of data issue while keeping the result reviewable.

### 2. Generate serving review

```bash
uv run python generate_serving_review.py
```

This writes `data/step-9-out-serving-review.csv`, one row per distinct food.
The review contains serving mode, reference nutrient basis, example source
values, and editable serving-gram fields.

### 3. Match foods against existing CalCo products

```bash
uv run python generate_food_match_review.py
```

This writes a food match review CSV and machine-readable JSONL. Reuse an
existing CalCo food only when name, serving semantics, and nutrition are all
compatible. If matcher logic changes, write a fresh output and compare it
before merging decisions into an existing finalized review CSV.

### 4. Generate private foods for unresolved rows

```bash
uv run python generate_foods_to_create.py --selection all-unmatched
```

This writes `data/foods_to_create.jsonl` from the finalized match review. Rows
with accepted existing-food matches are skipped.

### 5. Create missing foods through the API

Start the backend separately, then create foods with a valid CalCo session
token:

```bash
uv run python create_foods.py \
  --api-url http://127.0.0.1:3001 \
  --visibility private \
  --session-token <calco_session_cookie_value>
```

The script posts to `POST /api/foods/custom`, writes returned IDs back into the
finalized review CSV, and preserves mapped MFP nutrients. Missing required macro
nutrient codes are backfilled with `0` only for API compatibility.

### 6. Import diary history

```bash
uv run python import_history.py \
  --api-url http://127.0.0.1:3001 \
  --session-token <calco_session_cookie_value>
```

The history importer uses the finalized food mapping, computes stable MFP row
fingerprints, skips already imported rows, and posts logs through the user-facing
logs API.

## Important Artifacts

| Artifact | Purpose |
| --- | --- |
| `data/step-9-out-serving-review.csv` | Manual serving and nutrient-basis review surface. |
| `data/step-10-out-food-match-review.csv` | Matcher output for existing CalCo products. |
| `data/step-10-out-food-match-review-merged.csv` | Finalized match/create decision surface when present. |
| `data/existing_food_matches.jsonl` | Machine-readable accepted existing-food matches. |
| `data/existing_food_matches-merged.jsonl` | Machine-readable finalized matches when present. |
| `data/foods_to_create.jsonl` | API payload input for unresolved private foods. |

The README and current scripts define the active workflow.

## Nutrient Mapping

Direct MFP nutrient mappings:

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

Daily-value fields are converted to absolute units before storage:

| MFP column | CalCo nutrient code | Formula |
| --- | --- | --- |
| `vitamin_d_pct_daily_value` | `VITAMIN_D_UG` | `pct / 100 * 20` |
| `iron_pct_daily_value` | `IRON_MG` | `pct / 100 * 18` |
| `vitamin_a_pct_daily_value` | `VITAMIN_A_UG` | `pct / 100 * 900` |
| `vitamin_c_pct_daily_value` | `VITAMIN_C_MG` | `pct / 100 * 90` |

`15`, `15.0`, and `15%` all mean `15%`. Blank nutrient fields are skipped and
explicit zeroes are preserved.

## Development Checks

Run from this directory:

```bash
nix develop ../../.. --command uv run ruff check .
nix develop ../../.. --command uv run ty check .
nix develop ../../.. --command uv run python -m unittest discover -s src -p 'test_*.py'
```

Useful smoke test:

```bash
uv run python src/clean.py --data-dir data
uv run python generate_serving_review.py
```
