# Step 10 Matcher Handoff

Date: 2026-06-11

## Start Here

The next bot should start from this document and treat
`data/step-10-out-food-match-review-merged.csv` as the current source of truth
for final food ID mapping.

Do not regenerate or overwrite that merged CSV blindly. If matcher logic is
improved and rerun, write a fresh review output first, compare the delta
against the merged CSV, and merge only newly accepted additions.

## Current Artifacts

Primary working files:

- `data/step-10-out-food-match-review-merged.csv`
- `data/existing_food_matches-merged.jsonl`
- `data/foods_to_create.jsonl`

Supporting reports:

- `data/step-10-match-report.md`
- `data/step-10-macro-close-report.md`

Matcher implementation and tests:

- `generate_food_match_review.py`
- `src/steps/generate_food_match_review.py`
- `src/test_generate_food_match_review.py`

## What Has Been Done

1. Implemented `generate_food_match_review.py` and the step module.
2. Added conservative direct-Postgres matching against global catalog foods.
3. Improved matching to:
   - compare `per_serving` foods on a derived per-100g basis using reviewed
     serving grams
   - search with multiple normalized and alias-expanded query terms
   - allow exact/strong liquid matches with macro comparison
   - record top-candidate diagnostics into `match_notes` for unmatched rows
4. Ran the matcher against the local CalCo Postgres catalog.
5. Generated:
   - `step-10-out-food-match-review.csv`
   - `existing_food_matches.jsonl`
   - `step-10-match-report.md`
6. Generated an alternate nutrition-close review slice:
   - `step-10-macro-close-report.md`
7. Manually approved the following macro-close groups into a merged review CSV:
   - all `Strong Review Candidates`
   - all `Plausible But Needs Care`
   - except `Malka Masur Dal -> Lentils, raw`
8. Wrote merged outputs:
   - `step-10-out-food-match-review-merged.csv`
   - `existing_food_matches-merged.jsonl`
9. Improved matcher normalization, alias expansion, and category-aware
   tolerances for the step-10 follow-up foods.
10. Reran the matcher into fresh review outputs:
   - `step-10-out-food-match-review-rerun.csv`
   - `existing_food_matches-rerun.jsonl`
11. Merged additional conservative approvals from the rerun review, including:
   - `Almond Milk, Plain`
   - `Banana`
   - `Egg White`
   - `Egg white`
   - `Greek Yogurt, Natural`
   - `Amul High Protein Blueberry Shake`
   - `Eggs`
   - `Maggi 2 Minute Noodles`
   - `Nutella`
   - `Oats`
12. Generated `data/foods_to_create.jsonl` from the merged review CSV with
    `--selection all-unmatched`.
13. Created all remaining unmatched foods via `POST /api/foods/custom` against
    the running backend at `http://127.0.0.1:3001`.
14. Wrote returned custom-food IDs back into
    `data/step-10-out-food-match-review-merged.csv` as:
    - `created_food_id`
    - `created_food_name`
    - `final_food_id`
    - `final_food_name`
    - `final_action`
    - `ready_for_log_import`

## Current Match Counts

- matcher-only auto-matches: `23`
- merged/manual follow-up matches now present in working CSV: `33`
- total matched rows in merged CSV: `57`

## Current Finalization Counts

- matched-existing rows: `57`
- created-new rows: `225`
- total finalized rows: `282`
- rows with `ready_for_log_import=true`: `282`

## Current Decision Rules

The user set the following working rules for unresolved step-10 rows before the
creation run:

1. Do not spend more time searching for branded products in external sources.
2. Use `data/step-10-out-food-match-review-merged.csv` as the source of truth
   for which rows are already matched.
3. If a row still has no `matched_food_id`, include it in
   `foods_to_create.jsonl`.
4. `Apple` is already matched in the merged CSV/JSONL and should therefore not
   appear in `foods_to_create.jsonl`.
5. Do not overwrite the merged CSV blindly during downstream creation work.

## Current Foods-To-Create Status

The maintained generator is now:

- `generate_foods_to_create.py`
- `src/steps/generate_foods_to_create.py`
- `src/test_generate_foods_to_create.py`

Generator modes:

- `--selection approved-policy`
  - emits only the earlier explicitly approved branded/raw-basic custom-food
    buckets
- `--selection all-unmatched`
  - emits every unresolved row in the merged CSV

Current working output:

- `data/foods_to_create.jsonl`
  - generated from `data/step-10-out-food-match-review-merged.csv`
  - generated with `--selection all-unmatched`
  - contains `225` records, equal to the unmatched-row count used for custom
    food creation

## Current State

Custom-food creation is complete. There are currently no unresolved rows in the
merged review CSV.

Future matcher work is optional and should only happen if catalog reuse quality
needs improvement before a later re-import or cleanup pass.

## Recommended Working Rule For The Next Bot

Use `data/step-10-out-food-match-review-merged.csv` as the current source of
truth for historical log import. Do not overwrite it blindly. If matcher logic
is improved and rerun later, write a new review output first, compare the delta
against the finalized merged CSV, and merge only explicitly accepted changes.
