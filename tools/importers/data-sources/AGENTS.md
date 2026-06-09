# Data Sources Agent Instructions

This directory contains the catalog dataset import pipeline for CalCo. Also
read `../../../AGENTS.md`, `../../../docs/imports.md`, and `README.md` before
changing importer behavior.

## Shape

- Python 3.12 project managed with `uv`.
- Dataset converters produce normalized JSONL rows for the backend import API.
- `calco_import` package: fetch raw data, convert to JSONL, merge sources with
  dedup, upload via the backend import pipeline.

## Import Boundaries

- Imports are CLI workflows, not browser UI.
- Converters intentionally project raw datasets into CalCo's current product
  model. Adding fields such as ingredients or allergens is a backend schema and
  domain change, not a converter-only flag.
- Backend catalog import rows should use uppercase source codes such as `OFF`,
  `USDA`, `IFCT`, and `INDB`.
- Import scripts should prefer existing CalCo APIs over direct database writes.

## Checks

Run from this directory:

```bash
nix develop ../../.. --command uv run ruff check src/
nix develop ../../.. --command uv run ty check src/
nix develop ../../.. --command uv run python -m unittest discover -s . -p 'test_*.py'
```
