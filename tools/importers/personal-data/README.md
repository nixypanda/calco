# CalCo Personal Data Import Tools

This directory centers on the structured MFP cleaning pipeline under `src/`
and the generated review artifacts under `data/`.

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

Next, use that review CSV to:

- match foods against existing DB foods
- create JSONL for foods that do not have a safe existing match
- write final DB food IDs and canonical names back into the CSV
- use the finalized CSV as the reference contract for historical log import

## Serving Review Output

`step-9-out-serving-review.csv` contains one row per distinct food with:

- `serving_mode`: `mass`, `volume`, or `serving_unit`
- `reference_basis`: `per_100g`, `per_100ml`, or `per_serving`
- `reference_*` nutrient columns on that basis
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

## Current Step-10 Status

The current working review surface is:

- `data/step-10-out-food-match-review-merged.csv`

This file includes:

- `18` matcher auto-matches
- `25` manually approved macro-close matches
- `43` total matched rows

The original matcher-only outputs are still preserved in:

- `data/step-10-out-food-match-review.csv`
- `data/existing_food_matches.jsonl`

The merged files should be treated as the current base for downstream
unmatched-food creation work unless a later review supersedes them.

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
