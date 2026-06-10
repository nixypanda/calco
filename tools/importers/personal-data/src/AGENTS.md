# MFP Data Cleaning Pipeline

## What This Is

A multi-step cleaning pipeline that transforms raw MyFitnessPal export CSVs
into clean, reviewable import data. Each step fixes one category of data issue.
The maintained workflow ends in pipeline-owned CSV artifacts under `../data/`.

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
- Step 2: `step-2-out-scale_values.csv`
- Step 3: `step-3-out-flag_pseudo_grams.csv`
- Step 4: `step-4-out-check_macro_calories.csv`
- Step 5: `step-5-out-fix_macro_mismatches.csv`
- Step 6: `step-6-out-resolve_serving_modes.csv`
- Step 7: `step-7-out-deduplicate.csv`
- Step 8: `step-8-out-canonicalize_food_descriptions.csv`

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

### Step 4: `check_macro_calories` — DONE

Audit rows where stated calories don't match the sum from macros
(protein×4 + carbs×4 + fat×9). Marks an `is_mismatch` flag column and
writes a review file of mismatched rows for manual inspection.

Output: `step-4-out-check_macro_calories.csv` + `step-4-review-macro-mismatch.csv`

### Step 5: `fix_macro_mismatches` — DONE

Apply corrections to macro-calorie mismatches flagged by step 4 using a
corrections file applied as an overlay.

Output: `step-5-out-fix_macro_mismatches.csv` + `step-5-corrections.csv`

### Step 6: `resolve_serving_modes` — TODO

13 foods appear with different serving types on different dates
(e.g., Kali Dal Makhani as both `1.0 g` pseudo-serving and `125.0 g`
real grams). This step assigns a canonical serving mode per food name.

See `merged-data-analysis.md` §Issue 3 for the full list.

Output a review file for foods that need manual mode assignment.

### Step 7: `deduplicate` — DONE

Remove byte-identical duplicate rows (every column equal).

After manual review, the 8 food groups with matching `(date, meal, description,
serving)` split into:

- **4 groups truly identical** (Paneer Paratha, Curd, Bread, Whole wheat bread)
  — export artifacts, stripped by this step (~16 rows across all item types).
- **4 groups with conflicting values** (multi-protein bread, AS Protein Bread,
  Punjabi Kadhi, White rice cooked) — confirmed intentional: the user logged two
  different serving amounts of the same food in the same meal entry. Left untouched.

Rows with different values on the same key are **not** considered duplicates.

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

## Downstream

The maintained downstream review artifact is
`data/step-9-out-serving-review.csv`, generated by
`../generate_serving_review.py`.

That review file is the handoff for later JSONL/import tooling:

1. food descriptions are already canonicalized
2. serving mode is explicit (`mass`, `volume`, `serving_unit`)
3. review edits live with the pipeline output instead of legacy `apps/` files
