# Catalog Data Sources Importer

Converts public food composition datasets into normalized CalCo catalog rows
and uploads them through the backend import API.

## Supported Sources

| Source | Dataset code | Typical input |
| --- | --- | --- |
| USDA SR Legacy | `usda` | `FoodData_Central_sr_legacy_food_json_2018-04.zip` |
| Open Food Facts India | `off` | `off_products.csv.gz` |
| IFCT 2017 | `ifct` | `ifct2017_compositions.csv` |
| INDB 2024 | `indb` | `Anuvaad_INDB_2024.11.xlsx` |

The importer emits normalized food, nutrient, and serving JSONL rows compatible
with the backend import API documented in `../../../docs/imports.md`.

## CLI

Run commands from this directory:

```bash
uv run calco-import <command> <dataset> [options]
```

The executable wrapper is also available as:

```bash
./calco-import <command> <dataset> [options]
```

Commands:

| Command | Description |
| --- | --- |
| `fetch` | Download or read the source dataset and convert it to processed JSONL. |
| `merge` | Deduplicate processed source outputs into one merged dataset. |
| `upload` | Upload processed JSONL to the backend import API. |
| `import` | Run the full workflow for a dataset. |

Datasets: `usda`, `off`, `ifct`, `indb`, `merged`.

Common options:

| Option | Environment variable | Default |
| --- | --- | --- |
| `--api-url` | `CALCO_API_URL` | `http://localhost:3001` |
| `--session-token` | `CALCO_SESSION_TOKEN` | interactive prompt |
| `--data-dir` | `CALCO_DATA_DIR` | `./data` |
| `--dry-run` | none | skip upload side effects |

## Examples

```bash
# Convert one source into processed JSONL.
uv run calco-import fetch ifct

# Convert all public sources and merge them.
uv run calco-import fetch usda
uv run calco-import fetch off
uv run calco-import fetch ifct
uv run calco-import fetch indb
uv run calco-import merge

# Upload a merged dataset to a running backend.
CALCO_SESSION_TOKEN=<token> uv run calco-import upload merged
```

For local checks without writing into the working tree, set a temporary data
directory:

```bash
CALCO_DATA_DIR=/tmp/calco-import-verify uv run calco-import fetch usda
```

## Data Layout

Generated data normally lives under `data/`:

| Subdirectory | Contents |
| --- | --- |
| `raw/` | Downloaded or copied source files. |
| `processed/` | Normalized per-source JSONL outputs. |
| `reference/` | Local reference outputs used for snapshot comparisons. |

Do not commit downloaded archives or generated outputs unless the repository
explicitly tracks a fixture.

## Converter Contract

- Emit uppercase source codes such as `USDA`, `OFF`, `IFCT`, and `INDB`.
- Preserve stable `source_id` values so backend upserts are repeatable.
- Project source data into CalCo's current product, nutrient, and serving
  model.
- Treat new fields such as allergens or ingredients as backend schema work, not
  importer-only additions.

## Snapshot Checks

Use reference outputs to verify converter changes:

```bash
CALCO_DATA_DIR=/tmp/calco-import-verify uv run calco-import fetch usda
diff <(sort data/reference/usda_sr_legacy.jsonl) \
  <(sort /tmp/calco-import-verify/processed/usda_sr_legacy.jsonl)
```

Repeat for any dataset whose converter changed. Update reference outputs only
when the data change is intentional.

## Development Checks

Run from this directory:

```bash
nix develop ../../.. --command uv run ruff check src/
nix develop ../../.. --command uv run ty check src/
nix develop ../../.. --command uv run python -m unittest discover -s . -p 'test_*.py'
```
