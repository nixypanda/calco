# Importers Agent Instructions

This directory contains Python import and conversion tools for CalCo. Also read
`../../AGENTS.md`, `../../docs/imports.md`, and `README.md` before changing
import behavior.

## Shape

- Python 3.12 project managed with `uv`.
- Dataset converters produce normalized JSONL rows for the backend import API.
- `import_pipeline.py` creates an import job, uploads batches, commits, and
  fetches errors.
- `mfp_import.py` imports a user's MyFitnessPal privacy export into that user's
  private CalCo foods and diary history.

## Import Boundaries

- Imports are CLI workflows, not browser UI.
- Converters intentionally project raw datasets into CalCo's current product
  model. Adding fields such as ingredients or allergens is a backend schema and
  domain change, not a converter-only flag.
- Backend catalog import rows should use uppercase source codes such as `OFF`,
  `USDA`, and `IFCT`.
- Import scripts should prefer existing CalCo APIs over direct database writes.

## MyFitnessPal Importer Rules

- Do not edit `apps/mfp-data.csv`; it is the preserved raw privacy export.
- Use `apps/mfp-data-working-cleaned.csv` for import-specific row corrections.
- `mfp-food-review.csv` is the editable review gate for food commits.
- `mfp-food-map.json` is the source of truth for history import after food
  commit. Do not make history import search the catalog again.
- Do not switch history import to direct nutrient snapshot insertion without a
  product/design decision.
- The MFP export can contain personal account fields. Avoid logging or
  documenting those values.

## Checks

Run from this directory:

```bash
nix develop ../.. --command uv run ruff check .
nix develop ../.. --command uv run ty check .
nix develop ../.. --command uv run python -m unittest discover -s . -p 'test_*.py'
```

Useful smoke test:

```bash
python3 mfp_import.py food-dry-run --output /private/tmp/mfp-food-review.csv
```

