# Fix Macro-Calorie Mismatches Plan

**Context**: Step 4 (`check_macro_calories`) flagged 416 rows (11.7%) where
stated calories differ from `protein×4 + carbs×4 + fat×9` by >20%. These
mismatches exist because MFP's macro detail columns have gaps or
inconsistencies.

**Resolution principle**: Trust stated `calories` as more reliable. Fix the
macro columns to be consistent.

---

## 1. Inventory — 42 unique foods, 416 rows

### Category A: Raw produce (6 foods, 129 rows)

| Food | Rows | Avg diff % | Notes |
|------|------|-----------|-------|
| Cucumber | 86 | 20.7 | USDA: fat=0.1, carbs=3.6, prot=0.7 per 100g |
| Muskmelon | 16 | 21.5 | USDA: fat=0.2, carbs=8.2, prot=0.8 per 100g |
| Guava | 12 | 40.3 | USDA: fat=0.9, carbs=14.3, prot=2.6 per 100g |
| Watermelon | 8 | 20.9 | USDA: fat=0.2, carbs=7.6, prot=0.6 per 100g |
| Kiwi | 6 | 27.2 | USDA: fat=0.5, carbs=14.7, prot=1.1 per 100g |
| Lettuce | 1 | 24.7 | USDA: fat=0.1, carbs=2.9, prot=0.9 per 100g |

**Fix**: Look up USDA per-100g values, compute `macro = canonical × value / 100`.

### Category B: Raw protein & egg dishes (5 foods, 143 rows)

| Food | Rows | Avg diff % | Notes |
|------|------|-----------|-------|
| Eggs, boiled | 108 | 21.4 | USDA per large egg: fat=5.3, carbs=0.6, prot=6.3 |
| Brest (chicken breast) | 22 | 20.9 | USDA: fat=3.6, carbs=0, prot=31 per 100g |
| Omelette | 5 | 26.2 | Approx: 2 eggs, fat=12, carbs=1, prot=13 |
| 2 Egg White Omlette | 1 | 24.6 | Egg whites: fat=0, carbs=0.5, prot=4 per white |
| tofu | 1 | 28.0 | USDA: fat=4.8, carbs=1.9, prot=8.1 per 100g |

**Fix**: USDA canonical values, scaled by row value.

### Category C: Packaged / branded products (16 foods, 50 rows)

| Food | Rows | Notes |
|------|------|-------|
| Amul High Protein Blueberry Shake | 27 | Indian product — check label |
| Butter, salted | 3 | USDA: fat=81, carbs=0.1, prot=0.9 per 100g |
| Bournville 70% dark chocolate | 2 | Label: fat=42, carbs=37, prot=8.8 per 100g |
| Nutella | 2 | Label: fat=31, carbs=58, prot=6 per 100g |
| Mustard Oil | 2 | Pure fat: fat=100, carbs=0, prot=0 per 100g |
| Silk Fruit and Nut | 1 | Check product label |
| Mix seeds | 1 | Likely seed mix — USDA sunflower/pumpkin blend |
| Masala cup noodles | 1 | Indian packaged — check label |
| Vada Pav (packaged Pav) | 1 | Check label |
| Unsweetened Blueberry Protein Chocolate | 1 | Check label |
| stevia sweetened chocolate | 1 | Check label |
| Corona Extra Can | 1 | USDA beer: carbs ≈ 13 per 355ml |
| Øl (beer) | 1 | General beer profile |
| Regular | 1 | Unclear — needs identification |
| mocktail | 1 | Unknown — proportional scaling |
| Protein Bar | 1 | Check label |

**Fix**: Research each product. If label data unavailable → proportional scaling.

### Category D: Indian sabzi/dishes (13 foods, 149 rows)

| Food | Rows | Avg diff % | Notes |
|------|------|-----------|-------|
| Lauki Sabzi | 42 | 29.5 | All macros present but ratios off |
| Kaddu Ki Sabzi | 34 | 28.4 | All macros present |
| Baingan Bharta | 27 | 26.4 | All macros present |
| Aloo Baingan Veg | 13 | 71.2 | Fat/carbs notably mismatched |
| Aloo Posto | 14 | 45.6 | Poppy seed paste dish — fat likely understated |
| Mixed Veg | 14 | 41.5 | All macros present |
| French Beans Veggie (Sabzi) | 6 | 135.5 | Fat overstated relative to cal |
| Karela Meetu | 5 | 85.5 | Macros inconsistent |
| Aloo Ghobi | 3 | 25.8 | All macros present |
| Corn Masala Subji | 3 | 23.8 | All macros present |
| Kundru Sabji - Wok Stir Fried | 7 | 51.0 | All macros present |
| Vegetable Stir fry | 2 | 23.3 | All macros present |
| Sabji | 13 | 71.4 | **Fat=0, Prot=0** — macros missing entirely |

**Fix**: Proportional scaling (keeps macro ratios, scales to match stated
calories). Exception for "Sabji" — needs a template Indian sabji profile.

### Category E: Indian dal/curry (8 foods, 62 rows)

| Food | Rows | Avg diff % | Notes |
|------|------|-----------|-------|
| Moong (Yellow) Dal | 30 | 29.8 | All macros present |
| Chana Dal | 18 | 21.1 | All macros present |
| Black Eye Peas (Lobia) | 5 | 32.9 | All macros present |
| Green Moong Dal | 3 | 32.3 | All macros present |
| Sambhar | 2 | 30.2 | All macros present |
| Shahi Paneer | 2 | 36.7 | Rich dish — fat may be correct but not matching cal |
| Chole Palak | 1 | 144.6 | 20g fat for 123 cal — clear mismatch |
| Mutton Rogan Josh | 1 | 40.8 | All macros present |

**Fix**: INDB/recipe lookup if available, else proportional scaling.

### Category F: Indian bread (2 foods, 2 rows)

| Food | Rows | Notes |
|------|------|-------|
| Aloo Parantha (Large) | 1 | Recipe: fat≈9, carbs≈26, prot≈5 per piece |
| Methi Paratha | 1 | Recipe: fat≈12, carbs≈35, prot≈7 per piece |

**Fix**: Recipe approximation or proportional scaling.

### Category G: Boiled/prepared basics (3 foods, 12 rows)

| Food | Rows | Notes |
|------|------|-------|
| Steamed (steamed rice?) | 10 | **Fat=0, Prot=1.5** for 195 cal — likely rice |
| Boiled Chickpeas | 1 | USDA: fat=2.6, carbs=27, prot=9 per 100g |
| Boiled Rajma | 1 | USDA: fat=0.4, carbs=22, prot=9 per 100g |

**Fix**: USDA values. For "Steamed" — assign white rice profile
(fat=0.3, carbs=45, prot=4 per 100g).

---

## 2. Data sources (priority order)

1. **CalCo catalog** — `GET /api/foods/search?q=<name>` for already-indexed foods
2. **USDA FoodData Central** — `https://fdc.nal.usda.gov/` for raw foods & basics
3. **INDB** — Indian foods via `tools/importers/data-sources/`
4. **Product labels** — manufacturer websites
5. **Proportional scaling** — fallback for compound dishes

## 3. Proportional scaling formula

When macro ratios are trusted but absolute values don't match stated calories:

```
Given: stated_cal, old_fat, old_carbs, old_prot
Compute: total = old_fat*9 + old_carbs*4 + old_prot*4
Compute: fat_ratio = old_fat*9 / total
         carbs_ratio = old_carbs*4 / total
         prot_ratio = old_prot*4 / total
New: fat = stated_cal * fat_ratio / 9
     carbs = stated_cal * carbs_ratio / 4
     prot = stated_cal * prot_ratio / 4
```

For macro-zero entries (Sabji, Steamed): use template ratios:
- Indian sabji template: 55% carbs, 35% fat, 10% protein
- Steamed rice template: 85% carbs, 5% fat, 10% protein

## 4. Review step

Build a correction table CSV with columns:
```
food_name, fat_g, carbs_g, protein_g, source, method
```

Show user for approval before applying.

## 5. Apply fixes

Script: `src/fix_macro_mismatches.py`

- Read `step-3-out-flag_pseudo_grams.csv`
- Apply corrections from approved table (exact food name match)
- For non-matched compound dishes: apply proportional scaling
- Write updated CSV over the original or to a new file
- Stats: total rows fixed, corrections applied, remaining mismatches

## 6. Verify

```bash
# Re-run from step 3
python3 clean.py --skip 0 1 2
# Check step 4 output — should show 0 or near-0 mismatches
# If some remain at just-over-20%, consider adjusting threshold
```
