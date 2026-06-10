"""Step 6: Resolve inconsistent serving modes for the same food.

Reads step-5 output, detects foods logged with multiple serving types
(e.g., grams + cups, grams + servings), and resolves them.

Resolution strategies:
  - Already harmonised (all gram entries): pass through.
  - Known volume-to-gram conversions: multiply by fixed factor.
  - Gram + discrete units: infer gram weight from average density of
    gram entries of the same food.
  - Homemade entries logged as omelette: relabel to "Sunny Side Up Egg"
    (their macro profile matches the existing Sunny Side Up Egg entries,
    not the generic "Homemade" entries at 77 cal/100g).
"""

import csv
from collections import defaultdict
from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv, write_csv


# ---- helpers ----

def _dec(val: str) -> Decimal | None:
    v = val.strip()
    if not v:
        return None
    try:
        return Decimal(v)
    except InvalidOperation:
        return None


# ---- conversion maps ----

# Volume-to-gram conversion factors.
# Key: (food_name, from_unit) → grams per unit.
VOLUME_TO_GRAMS: dict[tuple[str, str], Decimal] = {
    ("Wild Blueberry Fruit Spread", "tbsp"): Decimal("15"),
    ("Nutella", "tbsp"): Decimal("15"),
    ("Rajma", "cup"): Decimal("200"),
}


# ---- review file ----

REVIEW_HEADER = [
    "food_name",
    "resolution",
    "observed_units",
    "converted_entries",
    "notes",
]


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    # ---- Phase 1: collect per-food info ----
    food_info: dict[str, dict] = {}
    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            continue
        desc = row["description"].strip()
        unit = row["unit"].strip().lower()

        info = food_info.setdefault(desc, {
            "units": set(),
            "unit_counts": defaultdict(int),
            "gram_density_sum": Decimal(0),
            "gram_density_count": 0,
        })
        info["units"].add(unit)
        info["unit_counts"][unit] += 1

        if unit == "g":
            val = _dec(row["value"])
            cal = _dec(row["calories"])
            if val and val > 0 and cal and cal > 0:
                info["gram_density_sum"] += cal / val * Decimal("100")
                info["gram_density_count"] += 1

    # ---- Phase 2: apply resolution ----
    review: dict[str, dict] = {}
    total_converted = 0
    total_relabelled = 0

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            continue
        desc = row["description"].strip()
        unit = row["unit"].strip().lower()
        info = food_info.get(desc)
        if info is None or len(info["units"]) <= 1:
            continue

        # --- Case 1: Relabel Homemade omelette → Sunny Side Up Egg ---
        # These 2 entries (184 cal, F=14/C=0.8/P=13, serving="1.0 omelette")
        # match the existing Sunny Side Up Egg profile (180 cal, F=13.7/C=0.8/P=12.5),
        # not the generic "Homemade" entries (77 cal/100g, moderate everything).
        if desc == "Homemade" and unit != "g" and "omelette" in row.get("serving", "").lower():
            row["description"] = "Sunny Side Up Egg"
            total_relabelled += 1
            _record_review(
                review, "Homemade", "relabel",
                _fmt_units(info["unit_counts"]),
                notes='2 omelette entries relabelled to "Sunny Side Up Egg" '
                      '(matches 180 cal, F=13.7/C=0.8/P=12.5 profile)',
            )
            continue

        # --- Case 2: Known volume-to-gram conversion ---
        key = (desc, unit)
        if key in VOLUME_TO_GRAMS:
            factor = VOLUME_TO_GRAMS[key]
            val = _dec(row["value"])
            if val:
                row["value"] = str(val * factor)
                row["unit"] = "g"
                total_converted += 1
                _record_review(
                    review, desc, "auto",
                    _fmt_units(info["unit_counts"]),
                    notes=f"{unit}→g (×{factor})",
                )
            continue

        # --- Case 3: Infer gram weight from average density of gram entries ---
        # For foods mixing grams with discrete units (cup, serving, potato, bar)
        # where macro ratios are consistent between gram and non-gram entries.
        if unit != "g" and info["gram_density_count"] > 0:
            avg_density = info["gram_density_sum"] / info["gram_density_count"]
            cal = _dec(row["calories"])
            if cal and cal > 0 and avg_density > 0:
                implied_g = cal / avg_density * Decimal("100")
                row["value"] = str(implied_g)
                row["unit"] = "g"
                total_converted += 1
                _record_review(
                    review, desc, "auto",
                    _fmt_units(info["unit_counts"]),
                    notes=f"{unit}→{implied_g:.0f}g via density ({avg_density:.0f} cal/100g)",
                )

    write_csv(output_path, fieldnames, rows)

    output_dir = Path(output_path).parent
    review_path = output_dir / "step-6-review-serving-modes.csv"
    with open(review_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=REVIEW_HEADER)
        writer.writeheader()
        writer.writerows(review.values())

    return {
        "total_multi_mode_foods": len(review),
        "auto_resolved": len(review),
        "converted_to_grams": total_converted,
        "relabelled": total_relabelled,
        "review_file": str(review_path),
    }


# ---- small helpers ----

def _fmt_units(unit_counts: dict[str, int]) -> str:
    return ", ".join(f"{u}:{c}" for u, c in sorted(unit_counts.items()))


def _record_review(
    review: dict, food: str, resolution: str,
    units: str, notes: str = "",
) -> None:
    if food not in review:
        review[food] = {
            "food_name": food,
            "resolution": resolution,
            "observed_units": units,
            "converted_entries": 0,
            "notes": notes,
        }
    review[food]["converted_entries"] += 1
