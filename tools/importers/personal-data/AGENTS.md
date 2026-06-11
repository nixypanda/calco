# Personal Data Import Agent Instructions

This directory contains tools for cleaning and preparing personal nutrition
data for import into CalCo. Also read `../../AGENTS.md`,
`../../docs/imports.md`, and `README.md` before changing import behavior.

## Shape

- Python 3.12 project managed with `uv`.
- The maintained workflow is a step-based CSV cleaning pipeline under `src/`.
- The main generated artifacts live under `data/`.
- There is no maintained legacy importer path here; use the step-based
  pipeline under `src/` and the review artifacts under `data/`.

## Import Boundaries

- Imports are CLI workflows, not browser UI.
- The workflow is CLI-driven, not browser UI.
- Keep transformations explicit and reproducible as numbered pipeline steps.
- Review state should live in pipeline-owned CSVs under `data/`.

## Active Pipeline Outputs

- `src/clean.py` produces `data/step-0...step-8` outputs.
- `generate_serving_review.py` produces `data/step-9-out-serving-review.csv`.
- `step-9-out-serving-review.csv` is the maintained manual review contract.
- The raw MFP export can contain personal account fields. Avoid logging or
  documenting those values.

## Checks

Run from this directory:

```bash
nix develop ../../.. --command uv run ruff check .
nix develop ../../.. --command uv run ty check .
nix develop ../../.. --command uv run python -m unittest discover -s src -p 'test_*.py'
```

Useful smoke test:

```bash
python3 src/clean.py --data-dir data
python3 generate_serving_review.py
```
