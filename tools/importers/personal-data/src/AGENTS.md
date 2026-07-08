# MFP Cleaning Pipeline Agent Guardrails

Read `../README.md` and `README.md` before changing the cleaning pipeline.

- Keep each numbered step deterministic and reviewable.
- Preserve the MFP CSV title-row-plus-header format through shared helpers.
- Add or update focused unit tests for changed step behavior.
- Do not embed raw personal data values in docs, tests, or logs.

Use `uv run python -m unittest discover -s src -p 'test_*.py'` from
`tools/importers/personal-data` for the local test suite.
