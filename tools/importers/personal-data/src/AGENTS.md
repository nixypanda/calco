# MFP Data Cleaning Pipeline

## What This Is

A multi-step cleaning pipeline that transforms raw MyFitnessPal export CSVs
into clean, importable data. Each step fixes one category of data issue.
The final output is consumed by `mfp_import.py` (one directory up) to create
CalCo food products and diary logs.

## How To Run

```bash
cd src
python3 clean.py                  # run all steps
python3 clean.py --skip 0         # skip merge step (reuse existing output)
python3 clean.py --data-dir ../data  # default
```

## Input Data

All raw data lives in `../data/`:

| File | Schema | Source |
|------|--------|--------|
| `mfp-data.csv` | 38 cols: `item_type, date, description, value, unit, calories, fat_g, ...` | MFP privacy data export |
| `mfp-data-fixed.csv` | 12 cols: `date, food, brand, meal, serving, calories, protein, ...` | MFP direct app export |

## Output Convention

Every step writes `<data-dir>/step-<n>-out-<name>.csv`.

- Step 0: `step-0-out-merge_fixed_serving.csv`
- Step 1: `step-1-out-normalize_units.csv`
- etc.

Each step reads the previous step's output (except step 0 which reads the
two raw inputs). The clean.py orchestrator handles this chaining.

All output files use the MFP CSV format: a title row
(`sherubthakur Data Access Request,...`) followed by a CSV header row and data.

## Pipeline Steps

### Step 0: `merge_fixed_serving` — DONE

Merges the `meal` and `serving` columns from `mfp-data-fixed.csv` into
`mfp-data.csv`. Rows matched by `(date, description)` = `(date, food)`.

**Signature**: `run(raw_path, fixed_path, output_path) -> dict`

**Key column added**:
- `meal`: one of `Lunch`, `Dinner`, `Breakfast`, `Snacks`, `Supplements`
- `serving`: string of shape `<number> <unit>` (e.g., `250.0 g`, `1.0 egg`)

### Step 1: `normalize_units` — TODO

Normalize unit strings to canonical forms. The current data has ~55 variant
strings for ~10 actual unit concepts (see `merged-data-analysis.md` for the
full mapping).

**Signature**: `run(input_path, output_path) -> dict`

Canonical mapping to apply:
```
g, gm, gram, grams, gram(s), G, Gm, Gram, Grams, gms, gramme  → g
ml, mL                                                          → ml
piese, piece, pcs, pc                                           → piece
egg, eggs                                                       → egg
cup, Cup, Cups, cup cooked, cup, pieces, cup, popped            → cup (but drop parenthetical notes like "cup (250gm)")
bowl, Bowl, household bowl, katori, plate                       → bowl
kg(s)                                                           → g (convert to grams: value *= 1000)
ounce, oz                                                       → oz
tbsp, tbs, tablespoon                                           → tbsp
```

**Complications**:
- `cup (250 gm)`, `cup or 100g`, `sandwich (200g)` — the parenthetical is
  a note, not part of the unit. Strip it.
- `1` as a unit (2 entries) — data entry artifact. Value already accounts
  for it, so it can be treated as an empty unit.
- `"` as a unit (2 entries) — artifact, treat as empty.
- `medium (7" to 7-7/8" long)` — this is a size descriptor, not a unit.
  Collapse to `medium`.
- `Egg White` / `egg whites` — these are a unit concept. Collapse to
  `egg_white` (the importer handles it as a serving alias).
- `100 calorie package` — treat as `package`.

### Step 2: `scale_values` — TODO

Scale the `value` column by the numeric part of the `serving` column.

**Formula**: `new_value = value × serving_number`

Where `serving_number` is the numeric prefix of the `serving` column
(e.g., for `serving = "250.0 g"`, `serving_number = 250.0`).

**Why this works**:

The raw `value` in `mfp-data.csv` is MFP's internal quantity representation.
For pseudo-gram entries (serving=`1.0 g`), `value` holds the actual gram
amount (e.g., `value=400` for a 400g serving). For real-gram entries
(serving=`100.0 g`), `value` is typically `1` and the real quantity comes
from `serving_number`. The multiplication handles both cases:

| Food | `value` | `serving` | `value × number` | Meaning |
|------|---------|-----------|-------------------|---------|
| Kali Dal (pseudo-g) | 400 | `1.0 g` | 400 × 1.0 = 400 | 400g |
| Matar Mushroom | 1.6667 | `250.0 g` | 1.6667 × 250 = 416.7 | 416.7g |
| Eggs, boiled | 2 | `1.0 egg` | 2 × 1.0 = 2 | 2 eggs |
| Lettuce (real g) | 1 | `100.0 g` | 1 × 100 = 100 | 100g |

Use `steps.parse_serving()` to extract the numeric part.

The `unit` column should be updated to the unit text from the `serving`
column (which is already the canonicalized serving unit).

### Step 3: `flag_pseudo_grams` — TODO

Identify rows where `g` (or variants) is used as a fictional serving unit
rather than actual grams. These are entries with `serving_number = 1.0` and
unreasonably high calories for 1g of food (calories > 30 or so).

These entries need the `value` field to be trusted as the actual gram
amount (step 2 already handles the math, so this step is mainly for
reporting/review).

Output a review file (e.g., `step-3-review-pseudo-grams.csv`) alongside
the main cleaned CSV.

### Step 4: `deduplicate` — TODO

Remove exact duplicate logs — same `(date, meal, description, serving)`.

**Known duplicates** (8 groups found):
- Paneer Paratha, Curd, multi-protein bread, Bread, Whole wheat bread

For most, the rows are identical — keep one.
For `multi-protein bread` (2025-06-29, Snacks): one row has `value=1`,
the other `value=0.5`. These may be a correction, so keep the most recent
or sum them.

### Step 5: `resolve_serving_modes` — TODO

13 foods appear with different serving types on different dates
(e.g., Kali Dal Makhani as both `1.0 g` pseudo-serving and `125.0 g`
real grams). This step assigns a canonical serving mode per food name.

See `merged-data-analysis.md` §Issue 3 for the full list.

Output a review file for foods that need manual mode assignment.

## Step Contract

Every step module must expose a `run()` function with this signature:

```python
def run(input_path: str | Path, output_path: str | Path) -> dict:
    """Read input_path CSV, transform, write output_path CSV.

    Return a dict of summary stats (logged by the orchestrator).
    """
```

Exception: step 0 has two inputs:

```python
def run(raw_path: str | Path, fixed_path: str | Path, output_path: str | Path) -> dict:
```

## Shared Utilities (`steps/__init__.py`)

```python
load_csv(path)           # -> (fieldnames, rows) — skips title row
write_csv(path, fieldnames, rows)  # writes title + header + data
parse_serving(serving)   # -> (number_str, unit_str) — splits "250.0 g"
step_path(data_dir, n, name)  # -> Path("step-N-out-NAME.csv")
```

Use these for all CSV I/O to ensure consistent file format.

## Known Data Issues (see `merged-data-analysis.md` for full details)

1. **Unit variants** (~55 strings → ~10 canonical forms)
2. **Pseudo-gram serving** (461 rows where `g` = fictional serving, not grams)
3. **Inconsistent serving modes** (13 foods with different unit types)
4. **Macro-calorie mismatch** (421 rows where cal ≠ prot×4 + carbs×4 + fat×9)
5. **Missing nutrients** (added_sugar 100% empty, vit_d 71% empty, etc.)
6. **Compound food names** (530 rows with "and", "with", "+")
7. **Zero values** (1 row value=0, 3 rows cal=0 — supplements)
8. **Quantity-in-name** (5 rows where name contains serving size like "48 gms protein bread")

## Downstream: `mfp_import.py`

The final cleaned CSV feeds into the existing `mfp_import.py` pipeline:

1. `food-dry-run` — generates review CSV from the cleaned data
2. `food-commit` — creates/matches CalCo products
3. `history-import` — creates diary logs

The importer expects the same column layout as the original
`mfp-data-working-cleaned.csv` (38 columns), but with cleaned `value`/`unit`
and additional `meal`/`serving` columns.

The importer must implement the value-scaling logic:
```python
number, unit = parse_serving(row["serving"])
new_value = Decimal(row["value"]) * Decimal(number)
row["value"] = str(new_value)
row["unit"] = unit
```
