# CalCo Personal Data Import Tools

This directory now centers on the structured MFP cleaning pipeline under `src/`
and the generated review artifacts under `data/`.

Legacy artifacts such as `mfp_import.py` and `apps/` are preserved for
reference only and are not part of the maintained workflow.

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

## Serving Review Output

`step-9-out-serving-review.csv` contains one row per distinct food with:

- `serving_mode`: `mass`, `volume`, or `serving_unit`
- `reference_basis`: `per_100g`, `per_100ml`, or `per_serving`
- `reference_*` nutrient columns on that basis
- `example_value`, `example_unit`, `example_serving`
- `current_serving_grams`
- `corrected_serving_grams`
- `notes`

Rerunning `generate_serving_review.py` preserves existing values already entered
in `current_serving_grams`, `corrected_serving_grams`, and `notes`.

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
