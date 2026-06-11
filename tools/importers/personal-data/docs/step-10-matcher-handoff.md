# Step 10 Matcher Handoff

Date: 2026-06-11

## Current Artifacts

Primary working files:

- `data/step-10-out-food-match-review-merged.csv`
- `data/existing_food_matches-merged.jsonl`

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

## Current Match Counts

- matcher-only auto-matches: `18`
- merged manual approvals added: `25`
- total matched rows in merged CSV: `43`

## High-Row-Count Foods Still Missing Matches

Out of the top 20 by `row_count`, `13` remain unmatched. The user explicitly
expects these to have matches and asked for a follow-up plan:

- `Whey`
- `Roti`
- `Egg White`
- `Greek Yogurt, Natural`
- `Brest` (intended: chicken breast)
- `Banana`
- `Bread`
- `Almond Milk, Plain`
- `Paneer`
- `multi-protein bread`

## Next-Iteration Matcher Plan

### 1. Fix normalization and alias gaps

- map `brest -> breast`
- normalize `egg white` / `egg whites`
- normalize `Greek Yogurt, Natural` and `Greek Yogurt Natural`
- treat punctuation in exact-name liquids as non-distinguishing
- add search aliases for `roti -> chapati/phulka/flatbread`
- add search aliases for `paneer <-> panner`

### 2. Add category-aware tolerance rules

- `Egg White`: allow tiny absolute fat/carb drift near zero
- `Banana`: allow wider protein tolerance when kcal/carbs/fat are already close
- `Greek Yogurt, Natural`: allow slightly wider dairy carb/fat tolerance
- `Almond Milk, Plain`: allow wider liquid tolerance for exact-name matches only
- `Whey`: supplement rule where exact/near-exact name plus close
  kcal/protein/carbs can survive modest fat mismatch

### 3. Improve candidate retrieval

- `Roti`: expand search with `chapati`, `phulka`, `flatbread`
- `Paneer`: expand search for branded and misspelled variants
- `Whey`: search `whey protein`, `protein powder`
- `Brest`: search chicken-breast candidates after typo normalization
- `multi-protein bread`: search `protein bread`, `high protein bread`,
  `multigrain bread`

### 4. Investigate suspicious reference shapes

- `multi-protein bread` may have inflated per-100g values
- verify whether this is a real nutrition profile or an upstream serving /
  aggregation issue before forcing a match

### 5. Validation

- add explicit unit tests for these ten foods
- rerun matcher against local Postgres
- review only the newly promoted matches
- if accepted, merge them into the working merged CSV/JSONL

## Recommended Working Rule For The Next Bot

Use `data/step-10-out-food-match-review-merged.csv` as the current source of
truth for accepted existing-food matches. Do not overwrite it blindly. If the
matcher is improved and rerun, write a new review output first, compare the
delta, and then merge only the accepted additions.
