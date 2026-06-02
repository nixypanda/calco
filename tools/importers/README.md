# CalCo Importer Tools

This folder contains Python import/conversion tools for CalCo. The existing
dataset importers convert public food datasets into normalized catalog rows.
`mfp_import.py` is different: it imports a user's MyFitnessPal privacy export
into that user's private CalCo foods and diary history.

## MyFitnessPal Importer

Script:

```bash
python3 tools/importers/mfp_import.py <command>
```

Default input/output paths are under `tools/importers/apps/`:

```text
mfp-data.csv                 # source MyFitnessPal privacy export CSV
mfp-data-working-cleaned.csv # cleaned import copy; leave mfp-data.csv untouched
mfp-food-review.csv          # generated/editable food review CSV
mfp-food-map.json            # committed mapping from MFP food keys to CalCo product ids
mfp-history-mismatches.csv   # history import nutrient mismatch report
```

The source CSV currently used here is a MyFitnessPal data-access/privacy export,
not the Premium three-file ZIP. It has a title row, then a CSV header row, and
contains `Foods`, `Daily Nutrition Totals`, `Exercise`, and `Measurement` rows.
The importer intentionally processes only `item_type=Foods` for v1.

Keep `mfp-data.csv` as the original raw export. Any row-level corrections needed
for this import should be made in `mfp-data-working-cleaned.csv`, then commands
should be run with `--input importers/apps/mfp-data-working-cleaned.csv`.
`mfp-food-review.csv` is the active reviewed file and may be edited in place.

## Workflow

### 1. Food Dry Run

Generate a review CSV:

```bash
cd tools
python3 importers/mfp_import.py food-dry-run
```

Optional API-backed matching:

```bash
python3 importers/mfp_import.py food-dry-run \
  --api-url http://localhost:3001/api \
  --session-token <calco_session>
```

Without `--session-token`, dry-run still works and marks foods for `create`.
With a session token, it searches existing CalCo foods and suggests conservative
`match` rows when the name and energy look compatible.

Dry-run groups repeated rows by normalized MFP food description. After reviewed
cleanup, the current cleaned CSV has 273 approved candidate foods covering 3,584
importable `Foods` rows. One zero-value food row is intentionally skipped.

### 2. User Edits Review CSV

Edit `mfp-food-review.csv` before committing.

Important columns:

```text
mfp_food_key          stable key for this normalized MFP food description
description           representative MFP food name
row_count             number of MFP history rows grouped into this food
observed_units        unit frequencies seen in history
observed_quantities   common quantity/unit patterns
suggested_action      match, create, or skip
approved              yes/no gate used by food-commit
matched_product_id    required when suggested_action=match
canonical_name        name used when creating a private CalCo food
serving_mode          mass, serving_unit, or manual
serving_unit          product-specific serving unit, when needed
serving_grams         grams for 1 serving_unit, when known
notes                 free-form review notes
```

Review defaults are deliberately conservative:

- Foods with only mass units like `g` are usually `serving_mode=mass`.
- Foods with serving units like `piece` or `scoop` are usually
  `serving_mode=serving_unit`.
- Mixed mass/non-mass units are marked `serving_mode=manual` and
  `approved=no`.
- Suspicious mass rows with very high inferred kcal/100g are marked
  `approved=no`; this catches MFP rows where `gm` appears to mean a serving, not
  a literal gram.

Before commit, every row to import must have:

- `approved=yes`
- `suggested_action=match` with `matched_product_id`, or
  `suggested_action=create`
- `serving_mode` changed away from `manual`

For mixed-unit foods, one practical review pattern is:

```text
serving_mode=mass
serving_unit=cup
serving_grams=200
```

That creates a mass-based food for gram history rows and also adds a
product-specific `cup` serving alias for cup history rows.

### 3. Food Commit

Create/match the approved foods and write the resolved map:

```bash
python3 importers/mfp_import.py food-commit \
  --input importers/apps/mfp-data-working-cleaned.csv \
  --review importers/apps/mfp-food-review.csv \
  --session-token <calco_session>
```

Food commit uses existing CalCo APIs:

```text
GET  /api/foods/search
GET  /api/foods/{id}
POST /api/foods/custom
```

Rows marked `match` validate that the target product exists. Rows marked
`create` create a private custom food with:

```text
brand = MyFitnessPal
categories = ["mfp-import"]
source = USER
visibility = user_private
```

The output `mfp-food-map.json` is the contract for history import. It maps each
approved MFP food key to exactly one CalCo product id.

### 4. History Import

Import the MFP food diary rows:

```bash
python3 importers/mfp_import.py history-import \
  --input importers/apps/mfp-data-working-cleaned.csv \
  --session-token <calco_session>
```

History import uses only `mfp-food-map.json`; it does not search the catalog
again. Rows without an approved food map entry are skipped.

History import creates normal CalCo logs through:

```text
POST /api/logs
GET  /api/logs?from=YYYY-MM-DD&to=YYYY-MM-DD
```

Diary behavior:

- `logged_at` is set to `<date>T12:00:00Z`.
- `meal_slot` is `null`, so the current Diary UI shows these under `Other`.
- Log quantity/unit comes from the original MFP row and the resolved food map.
- Notes include a stable `mfp_row=<fingerprint>` marker.

Duplicate behavior:

- Before importing a date, the importer lists existing logs for that date.
- If a log already contains the same `mfp_row=<fingerprint>`, the row is skipped.
- This makes rerunning `history-import` safe for already imported rows.

Nutrition behavior:

- History uses normal CalCo product calculation by calling `POST /api/logs`.
- The importer compares the created CalCo nutrient snapshots against the
  original MFP row totals.
- Differences beyond tolerance are written to `mfp-history-mismatches.csv`.
- Current tolerances are 5 kcal for energy and 2 units for other nutrients.

## Supported Nutrients

Mapped MFP columns:

```text
calories                     -> ENERGY_KCAL
fat_g                        -> FAT_G
saturated_fat_g              -> SATURATED_FAT_G
trans_fat_g                  -> TRANS_FAT_G
polyunsaturated_fat_g        -> POLYUNSATURATED_FAT_G
monounsaturated_fat_g        -> MONOUNSATURATED_FAT_G
cholesterol_mg               -> CHOLESTEROL_MG
sodium_mg                    -> SODIUM_MG
carbs_g                      -> CARBS_G
fiber_g                      -> FIBER_G
sugar_g                      -> SUGAR_G
protein_g                    -> PROTEIN_G
calcium_mg                   -> CALCIUM_MG
potassium_mg                 -> POTASSIUM_MG
```

Ignored for v1:

```text
added_sugar_g
sugar_alcohols_g
vitamin_d_pct_daily_value
iron_pct_daily_value
vitamin_a_pct_daily_value
vitamin_c_pct_daily_value
```

Percent daily value columns are ignored because CalCo stores nutrient amounts in
actual units, not percentages.

## Verification Done

These commands passed locally:

```bash
cd tools/importers
nix develop ../.. --command uv run ruff check .
nix develop ../.. --command uv run ty check .
nix develop ../.. --command uv run python -m unittest discover -s . -p 'test_*.py'
python3 mfp_import.py food-dry-run --output /private/tmp/mfp-food-review.csv
```

## Notes For Future Agents

- The importer intentionally lives in tooling and avoids backend schema changes.
- Do not make history import search the catalog; the food map is the source of
  truth after food commit.
- Do not edit `mfp-data.csv`; it is the preserved raw export. Use
  `mfp-data-working-cleaned.csv` for import-specific row corrections.
- Do not switch history import to direct snapshot insertion without revisiting
  the product goal. The current design prioritizes reusable foods and search,
  while still reporting nutrition mismatches.
- The current MFP export contains personal account fields. Avoid logging or
  documenting those values.
