# Imports

Imports are handled from CLI scripts, not from a browser admin UI.

The import system has three parts:

- **Data sources pipeline** (`tools/importers/data-sources/`) for converting
  public food datasets into catalog rows via the backend import API.
- **Personal data import** (`tools/importers/personal-data/`) for importing user
  data from other apps (MyFitnessPal, etc.) via user-facing CalCo APIs. See
  [personal-data-import.md](personal-data-import.md).
- Backend import API for staging, validating, committing, and inspecting import
  jobs.

## Directory Map

| Path | Purpose |
| --- | --- |
| `tools/importers/data-sources/` | Converts public food datasets such as USDA, IFCT, INDB, and Open Food Facts into normalized catalog import rows. |
| `tools/importers/personal-data/` | Cleans and imports private user exports, currently MyFitnessPal data, through user-facing APIs. |

Operational tooling should stay CLI-oriented and reproducible, use existing
CalCo APIs over direct database writes, and keep application behavior in
`backend/` or `frontend-web/`. Do not commit raw personal exports, downloaded
source archives, generated caches, or local scratch outputs.

Use `data-sources/` when the source is a public catalog that should become
global searchable food data. Use `personal-data/` when the source belongs to a
single user and should create private foods, match existing foods, or import
diary history.

## Backend Flow (Data Sources Pipeline)

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
- Authoritatively synchronize product nutrients by canonical nutrient code.
- Authoritatively synchronize servings.
- Record unresolved or invalid rows as import errors.
- Freeze staging by moving a pending import to `running` before catalog writes.
- Retry a `running` import from the same staged batch after transient failures.
- Mark deterministic validation failures as `failed`; transient infrastructure
  failures leave the import `running`.
- Mark the import `committed` when done and reject any later commit attempt.

## Normalized Row Shapes

Food row:

```json
{
  "source": "USDA",
  "source_id": "123",
  "barcode": null,
  "name": "Rice, white, raw",
  "brand": null,
  "categories": ["grain"],
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
  "unit": "serving",
  "grams_per_unit": 30,
  "row_number": 1
}
```

## Catalog Data Sources CLI

The recommended entrypoint is the `calco-import` CLI app under
`tools/importers/data-sources/`:

```text
tools/importers/data-sources/
  calco-import                    ← executable wrapper
  src/calco_import/               ← Python package
    cli.py                        ← typer CLI, dispatch
    fetch/                        ← download + convert per dataset
    merge.py                      ← dedup logic
    pipeline.py                   ← upload logic
    util.py                       ← shared helpers
  nutrient_mapping/
```

### Supported Sources

| Source | Dataset code | Typical input |
| --- | --- | --- |
| USDA SR Legacy | `usda` | `FoodData_Central_sr_legacy_food_json_2018-04.zip` |
| Open Food Facts India | `off` | `off_products.csv.gz` |
| IFCT 2017 | `ifct` | `ifct2017_compositions.csv` |
| INDB 2024 | `indb` | `Anuvaad_INDB_2024.11.xlsx` |

The Open Food Facts converter includes products with the exact `en:india`
country tag as well as GTINs allocated under GS1 India's `890` prefix. For
GTIN-14, the packaging indicator digit before the GS1 prefix is handled
separately. Products must still have positive energy, protein, carbohydrate,
and fat values to be imported.

### Usage

Run commands from `tools/importers/data-sources`:

```bash
uv run calco-import <command> <dataset> [options]
```

The executable wrapper is also available as:

```bash
./calco-import <command> <dataset> [options]
```

Commands:

| Command  | Description                                           |
| -------- | ----------------------------------------------------- |
| `fetch`  | Download raw data + convert to normalized JSONL.      |
| `merge`  | Deduplicate all fetched datasets into `merged.jsonl`. |
| `upload` | Upload a processed JSONL file to the backend API.     |
| `import` | `fetch` + `upload` (full pipeline for a dataset).     |

Datasets: `usda`, `off`, `ifct`, `indb`, `merged`

Options:

| Flag              | Env var               | Default                 |
| ----------------- | --------------------- | ----------------------- |
| `--api-url`       | `CALCO_API_URL`       | `http://localhost:3001` |
| `--session-token` | `CALCO_SESSION_TOKEN` | Prompts interactively   |
| `--data-dir`      | `CALCO_DATA_DIR`      | `./data`                |
| `--dry-run`       | —                     | Skip upload             |

The importer appends `/imports` to the API base URL. For the current backend,
set `CALCO_API_URL` to the API prefix:

```bash
export CALCO_API_URL=http://127.0.0.1:3001/api
```

Uploads are admin-only. `CALCO_SESSION_TOKEN` must be the value of an admin
`calco_session` cookie.

### Examples

```bash
# Upload the existing processed merged catalog JSONL.
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
just -f tools/justfile data-sources-upload merged data

# Fetch and convert all sources. This downloads large raw datasets,
# including Open Food Facts.
uv run calco-import fetch usda
uv run calco-import fetch off
uv run calco-import fetch ifct
uv run calco-import fetch indb

# Merge all sources
uv run calco-import merge

# Upload a dataset
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
uv run calco-import upload merged

# Full pipeline when session token is set
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
uv run calco-import import ifct

# Full pipeline for merged fetches all sources, merges, then uploads.
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
just -f tools/justfile data-sources-import merged

# Dry-run check
uv run calco-import --dry-run fetch ifct
uv run calco-import --dry-run fetch indb
```

For local checks without writing into the working tree, set a temporary data
directory:

```bash
CALCO_DATA_DIR=/tmp/calco-import-verify uv run calco-import fetch usda
```

### Data Layout

Generated data normally lives under `tools/importers/data-sources/data/`:

| Subdirectory | Contents |
| --- | --- |
| `raw/` | Downloaded or copied source files. |
| `processed/` | Normalized per-source JSONL outputs. |
| `reference/` | Local reference outputs used for snapshot comparisons. |

Do not commit downloaded archives or generated outputs unless the repository
explicitly tracks a fixture.

### Converter Contract

- Emit uppercase source codes such as `USDA`, `OFF`, `IFCT`, and `INDB`.
- Preserve stable `source_id` values so backend upserts are repeatable.
- Project source data into CalCo's current product, nutrient, and serving
  model.
- Treat new fields such as allergens or ingredients as backend schema work, not
  importer-only additions.

### Snapshot Checks

Reference outputs generated by the legacy converters are kept in
`tools/importers/data-sources/data/reference/` (`usda_sr_legacy.jsonl`,
`ifct2017.jsonl`, `indb_2024.jsonl`, `off_india.jsonl`). When making changes to
the converter pipeline, verify correctness by regenerating with the new code and
diffing against these references:

```bash
cd tools/importers/data-sources

# Generate new output in a temp dir
CALCO_DATA_DIR=/tmp/verify uv run calco-import fetch usda
CALCO_DATA_DIR=/tmp/verify uv run calco-import fetch indb

# Diff against reference
diff <(sort data/reference/usda_sr_legacy.jsonl) <(sort /tmp/verify/processed/usda_sr_legacy.jsonl)
diff <(sort data/reference/indb_2024.jsonl) <(sort /tmp/verify/processed/indb_2024.jsonl)
```

When the diff is clean and the changes are intentional, update the reference by
copying the new output:

```bash
cp /tmp/verify/processed/usda_sr_legacy.jsonl data/reference/
cp /tmp/verify/processed/indb_2024.jsonl data/reference/
```

The reference outputs are gitignored and managed locally. Run this for all
datasets (`usda`, `ifct`, `indb`, `off`) before and after any converter change.

### Development Checks

Run from `tools/importers/data-sources`:

```bash
nix develop ../../.. --command uv run ruff check src/
nix develop ../../.. --command uv run ty check src/
nix develop ../../.. --command uv run python -m unittest discover -s . -p 'test_*.py'
```

Each importer is a Python 3.12 project managed with `uv`. Run checks from the
specific importer directory so paths and package roots match the local project.

### End-To-End Pipeline Test

`tools/importers/tests/test_import_pipeline.py` is the large integration test
for both importers. It creates two throwaway databases, boots the backend
against each, runs the real catalog and MyFitnessPal CLIs on committed fixtures,
and asserts that the import is idempotent and that both databases end up with
identical logical state.

Prerequisites: a reachable PostgreSQL (the `docker-compose.yml` database), the
Rust toolchain, and the project dev shell so `psql`, `sqlx`, `cargo`, and `uv`
are on `PATH`.

```bash
just db-up db-wait
nix develop -c just test-importers-e2e
```

The databases are created as `calco_e2e_*` and dropped afterward. Override the
maintenance connection with `CALCO_TEST_PG_URL` if needed.

## Personal Data Import

The maintained MyFitnessPal workflow lives at
`tools/importers/personal-data/`. It covers:

- cleaning the raw export into reviewable pipeline CSVs
- manual serving and food-match review
- creating unresolved private foods through the CalCo API
- importing the reviewed history through the logs API

See [personal-data-import.md](personal-data-import.md) for the active workflow.

## Data Loss Tradeoff

Converters intentionally project raw datasets into the current CalCo product
model. Many source-specific fields are dropped, source category strings are
normalized into `categories`, and committed rows do not retain a raw source
payload. Keep the original source archives when future reprocessing may be
needed.

Adding fields such as ingredients or allergens is a schema/domain change, not a converter flag.
