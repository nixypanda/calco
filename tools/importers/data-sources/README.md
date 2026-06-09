# CalCo Data Sources Import Pipeline

This folder contains the catalog dataset import pipeline for CalCo. It converts
public food composition databases into normalized catalog rows and uploads them
via the backend import API.

## Supported Datasets

| Source | Code | Data |
|--------|------|------|
| USDA SR Legacy | `usda` | `FoodData_Central_sr_legacy_food_json_2018-04.zip` |
| Open Food Facts India | `off` | `off_products.csv.gz` |
| IFCT 2017 | `ifct` | `ifct2017_compositions.csv` |
| INDB 2024 | `indb` | `Anuvaad_INDB_2024.11.xlsx` |

## CLI

```bash
tools/importers/data-sources/calco-import <command> <dataset> [options]
```

Commands: `fetch`, `merge`, `upload`, `import`

See `../../../docs/imports.md` for full usage documentation.

## Snapshot Testing

Reference outputs are kept in `data/reference/`. Verify converter changes by
diffing against these references:

```bash
cd tools/importers/data-sources
CALCO_DATA_DIR=/tmp/verify uv run python -m calco_import fetch usda
diff <(sort data/reference/usda_sr_legacy.jsonl) <(sort /tmp/verify/processed/usda_sr_legacy.jsonl)
```
