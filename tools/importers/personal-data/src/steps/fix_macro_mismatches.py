"""Step 5: Fix macro-calorie mismatches.

Reads step-4 output (rows with macro_mismatch=TRUE), fixes the macro
columns to be consistent with stated calories.

Resolution principle: Trust stated calories as more reliable. Fix the
macro columns to be consistent.

Strategies per food category:
  A (raw produce):     USDA per-100g canonical values, scaled to stated cal
  B (raw protein):     USDA per-100g canonical values, scaled to stated cal
  C (branded):         Label per-100g values where known, else proportional scaling
  D (Indian sabzi):    Proportional scaling (template for Sabji macro-zero)
  E (Indian dal/curry):Proportional scaling
  F (Indian bread):    Recipe approximation per-100g, scaled to stated cal
  G (boiled basics):   USDA per-100g canonical (rice template for Steamed)

Proportional scaling fallback for compound dishes not in the
correction dictionary preserves macro ratios while matching stated cal.
"""

import csv
from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv, write_csv

# ---- Canonical values ----
# (fat_g, carbs_g, protein_g) per 100g (or per 100ml for liquids)
# Used when row.unit is g or ml (known gram/volume amounts).
CANONICAL: dict[str, tuple[float, float, float]] = {
    # Category A: Raw produce (USDA per 100g)
    "Cucumber": (0.1, 3.6, 0.7),
    "Muskmelon": (0.2, 8.2, 0.8),
    "Guava": (0.9, 14.3, 2.6),
    "Watermelon": (0.2, 7.6, 0.6),
    "Kiwi": (0.5, 14.7, 1.1),
    "Lettuce": (0.1, 2.9, 0.9),
    # Category B: Raw protein (USDA per 100g)
    "Brest": (3.6, 0, 31),
    "tofu": (4.8, 1.9, 8.1),
    # Category C: Branded products (label per 100g/ml)
    "Amul High Protein Blueberry Shake": (0.75, 9.5, 10),
    "Bournville 70% dark chocolate": (47.4, 40.7, 7.6),
    "Nutella": (30.9, 57.5, 6.3),
    "Butter, salted": (81, 0.1, 0.9),
    "Mustard Oil": (100, 0, 0),
    "Silk Fruit and Nut": (30.4, 58.1, 7.8),
    "Corona Extra Can": (0, 4.2, 0.3),
    "stevia sweetened chocolate": (43, 26, 10),
    # Category F: Indian bread (per 100g, recipe-derived)
    "Aloo Parantha (Large)": (8.6, 24.8, 4.8),
    "Methi Paratha": (21.8, 63.6, 12.7),
    # Category G: Boiled basics (USDA per 100g)
    "Steamed": (0.3, 28, 2.7),
    "Boiled Chickpeas": (2.6, 27, 9),
    "Boiled Rajma": (0.5, 22.8, 8.7),
}

# Template macro-ratios (fraction of calories from each macro)
# Used when fat and protein are both zero (macros missing entirely).
# Ratios: (fat_pct, carbs_pct, protein_pct)
TEMPLATES: dict[str, tuple[float, float, float]] = {
    "Sabji": (0.35, 0.55, 0.10),
}

# Gram-based units (canonical per-100g applies)
GRAM_UNITS = frozenset({"g", "gm", "gram", "grams", "gram(s)", "gms", "gramme"})

# Millilitre-based units
ML_UNITS = frozenset({"ml", "mL"})


# ---- helpers ----

def _dec(val: str) -> Decimal | None:
    v = val.strip()
    if not v:
        return None
    try:
        return Decimal(v)
    except InvalidOperation:
        return None


def _scale_macros_to_cal(fat: Decimal, carbs: Decimal, prot: Decimal,
                          cal: Decimal) -> tuple[Decimal, Decimal, Decimal]:
    """Proportional scaling: preserve macro ratios, match stated calories."""
    total = fat * 9 + carbs * 4 + prot * 4
    if total == 0:
        return fat, carbs, prot
    ratio = cal / total
    return fat * ratio, carbs * ratio, prot * ratio


def _apply_template(food: str, cal: Decimal) -> tuple[Decimal, Decimal, Decimal]:
    """Apply template ratios for a food with zero macro calories."""
    base = TEMPLATES.get(food, TEMPLATES["Sabji"])
    fat_pct, carbs_pct, prot_pct = base
    new_fat = cal * Decimal(str(fat_pct)) / 9
    new_carbs = cal * Decimal(str(carbs_pct)) / 4
    new_prot = cal * Decimal(str(prot_pct)) / 4
    return new_fat, new_carbs, new_prot


# ---- main step ----

REVIEW_HEADER = [
    "food_name",
    "source_type",
    "method",
    "count",
]

# These food names are NOT applied via canonical per-100g because they
# use non-gram units (cup, bowl, etc.). They only get proportional scaling.
# Listed here to avoid the correction-table warning for known items.
_KNOWN_NON_GRAM_FOODS = frozenset({
    "Moong (Yellow) Dal",
    "Kaddu Ki Sabzi [Indian Pumpkin Vegetable]",
    "Sabji",
    "Baingan Bharta",
    "Lauki Sabzi",
    "Aloo Baingan Veg",
    "Aloo Posto",
    "Mixed Veg",
    "French Beans Veggie (Sabzi)",
    "Karela Meetu",
    "Aloo Ghobi",
    "Corn Masala Subji",
    "Kundru Sabji - Wok Stir Fried",
    "Vegetable Stir fry",
    "Chana Dal",
    "Black Eye Peas (Lobia)",
    "Green Moong Dal",
    "Sambhar",
    "Shahi Paneer",
    "Chole Palak",
    "Mutton Rogan Josh",
    "Eggs, boiled",
    "Omelette",
    "2 Egg White Omlette",
    "Watermelon",
    "Kiwi",
    "Unsweetened Blueberry Protein Chocolate",
    "Mix seeds",
    "Masala cup noodles",
    "Vada Pav (packaged Pav )",
    "Regular",
    "mocktail",
    "Protein Bar",
    "Øl",
    "Aloo Parantha (Large)",
    "Methi Paratha",
})


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    corrections: dict[str, dict] = {}
    fixed_count = 0
    proportional_count = 0
    template_count = 0
    canonical_count = 0
    still_zero_count = 0

    new_fieldnames = list(fieldnames)
    # Ensure fat_g, carbs_g, protein_g are present
    for col in ("fat_g", "carbs_g", "protein_g"):
        if col not in new_fieldnames:
            new_fieldnames.append(col)

    for row in rows:
        if row.get("macro_mismatch", "") != "TRUE":
            continue

        description = row.get("description", "").strip()
        cal = _dec(row.get("calories", ""))
        if cal is None or cal == 0:
            continue

        old_fat = _dec(row.get("fat_g", "")) or Decimal(0)
        old_carbs = _dec(row.get("carbs_g", "")) or Decimal(0)
        old_prot = _dec(row.get("protein_g", "")) or Decimal(0)
        unit = row.get("unit", "").strip().lower()
        val = _dec(row.get("value", "")) or Decimal(1)

        old_total = old_fat * 9 + old_carbs * 4 + old_prot * 4
        source_type = ""
        method = ""

        # Case 1: Key macros missing (fat=0 and prot=0) → template
        missing_macros = (old_fat == 0 and old_prot == 0)
        if missing_macros:
            new_fat, new_carbs, new_prot = _apply_template(description, cal)
            if new_fat == old_fat and new_carbs == old_carbs and new_prot == old_prot:
                still_zero_count += 1
            template_name = TEMPLATES.get(description, TEMPLATES["Sabji"])
            source_type = "template"
            method = f"template ({template_name})"
            template_count += 1

        # Case 2: Known canonical and gram/ml unit → canonical + scale to cal
        elif description in CANONICAL and (unit in GRAM_UNITS or unit in ML_UNITS):
            cfat, ccarbs, cprot = CANONICAL[description]
            c_fat = Decimal(str(cfat))
            c_carbs = Decimal(str(ccarbs))
            c_prot = Decimal(str(cprot))

            if unit in ML_UNITS:
                multiplier = val / 100
            else:
                multiplier = val / 100

            serving_fat = c_fat * multiplier
            serving_carbs = c_carbs * multiplier
            serving_prot = c_prot * multiplier

            new_fat, new_carbs, new_prot = _scale_macros_to_cal(
                serving_fat, serving_carbs, serving_prot, cal
            )
            source_type = "canonical"
            method = f"canonical per-100g: ({cfat}, {ccarbs}, {cprot})"
            canonical_count += 1

        # Case 3: Has existing macros → proportional scaling
        else:
            new_fat, new_carbs, new_prot = _scale_macros_to_cal(
                old_fat, old_carbs, old_prot, cal
            )
            if new_fat == old_fat and new_carbs == old_carbs and new_prot == old_prot:
                continue  # unchanged
            source_type = "proportional"
            method = "proportional scaling (preserve ratios, match stated cal)"
            proportional_count += 1

        # Apply
        row["fat_g"] = str(new_fat)
        row["carbs_g"] = str(new_carbs)
        row["protein_g"] = str(new_prot)
        fixed_count += 1

        if description not in corrections:
            corrections[description] = {
                "food_name": description,
                "source_type": source_type,
                "method": method,
                "count": 0,
            }
        corrections[description]["count"] += 1

    write_csv(output_path, new_fieldnames, rows)

    output_dir = Path(output_path).parent
    review_path = output_dir / "step-5-corrections.csv"
    with open(review_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=REVIEW_HEADER)
        writer.writeheader()
        writer.writerows(corrections.values())

    return {
        "total_fixed": fixed_count,
        "canonical": canonical_count,
        "proportional_scaling": proportional_count,
        "template": template_count,
        "still_zero": still_zero_count,
        "corrections_file": str(review_path),
    }
