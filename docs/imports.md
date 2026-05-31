# Imports

## Overview

Imports are handled from CLI scripts, not from a browser admin UI.

The import system has two parts:

- Backend import API for staging, validating, committing, and inspecting import jobs.
- Python scripts in `tools/importers/` for converting external datasets, merging sources, and uploading normalized rows.

## Backend Flow

Import jobs are admin-only.

```text
POST /api/imports
POST /api/imports/{id}/foods
POST /api/imports/{id}/nutrients
POST /api/imports/{id}/servings
POST /api/imports/{id}/commit
GET  /api/imports/{id}
GET  /api/imports/{id}/errors
```

Staging tables:

- `staging_products`
- `staging_product_nutrients`
- `staging_product_servings`
- `import_errors`

Commit behavior:

- Upsert products by `(source, source_id)`.
- Insert/update product nutrients by canonical nutrient code.
- Insert/update servings.
- Record unresolved or invalid rows as import errors.
- Mark the import committed when done.

## Normalized Row Shapes

Food row:

```json
{
  "source": "USDA",
  "source_id": "123",
  "barcode": null,
  "name": "Rice, white, raw",
  "brand": null,
  "category": "grain",
  "serving_size_g": 100,
  "row_number": 1
}
```

Nutrient row:

```json
{
  "source": "USDA",
  "source_id": "123",
  "nutrient_code": "ENERGY_KCAL",
  "amount_per_100g": 365,
  "row_number": 1
}
```

Serving row:

```json
{
  "source": "OFF",
  "source_id": "abc",
  "label": "serving",
  "quantity": 1,
  "unit": "serving",
  "grams": 30,
  "row_number": 1
}
```

## Tooling

```text
tools/importers/
  convert_usda_sr.py
  convert_off_india.py
  convert_ifct2017.py
  merge_sources.py
  import_pipeline.py
  nutrient_mapping/
```

Converters:

- `convert_usda_sr.py`: USDA SR Legacy JSON to normalized JSONL.
- `convert_off_india.py`: Open Food Facts CSV filtered to India products.
- `convert_ifct2017.py`: IFCT 2017 CSV to normalized JSONL.

Merge:

- `merge_sources.py` deduplicates sources before import.
- Matching uses barcode where available and name similarity where needed.
- Macro consistency checks warn on likely false matches.
- Source preference is USDA, then IFCT, then OFF.

Pipeline:

- `import_pipeline.py` creates an import job, uploads batches, commits, and fetches errors.
- Auth uses the admin session cookie.

## Data Loss Tradeoff

Converters intentionally project raw datasets into the current CalCo product model. Many source-specific fields are dropped. This is accepted for now and tracked in [known issues](known_issues.md).

Adding fields such as ingredients or allergens is a schema/domain change, not a converter flag.
