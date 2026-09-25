# CalCo Importers

This directory contains import tooling for getting external nutrition data into
CalCo. Imports are command-line workflows, not browser admin screens.

## Importer Types

| Importer | Path | Data | Writes |
| --- | --- | --- | --- |
| Catalog data sources | `data-sources/` | Public datasets such as USDA, IFCT, INDB, and Open Food Facts | Backend admin import API |
| Personal data | `personal-data/` | Private exports from apps such as MyFitnessPal | User-facing food and log APIs |

Use `../../docs/imports.md` for backend import API concepts and row contracts.

## Choosing The Right Importer

Use `data-sources/` when the source is a public catalog that should become
global searchable food data.

Use `personal-data/` when the source belongs to a single user and should create
private foods, match existing foods, or import diary history.

## Checks

Each importer is a Python 3.12 project managed with `uv`. Run checks from the
specific importer directory so paths and package roots match the local project.

## End-To-End Pipeline Test

`tests/test_import_pipeline.py` is the large integration test for both
importers. It creates two throwaway databases, boots the backend against each,
runs the real catalog and MyFitnessPal CLIs on committed fixtures, and asserts
that the import is idempotent and that both databases end up with identical
logical state.

Prerequisites: a reachable PostgreSQL (the `docker-compose.yml` database), the
Rust toolchain, and the project dev shell so `psql`, `sqlx`, `cargo`, and `uv`
are on `PATH`.

```bash
just db-up db-wait
nix develop -c just test-importers-e2e
```

The databases are created as `calco_e2e_*` and dropped afterward. Override the
maintenance connection with `CALCO_TEST_PG_URL` if needed.

