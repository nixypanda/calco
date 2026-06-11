"""Step 9: Generate a serving review CSV for manual correction.

Reads the canonicalized step output, groups distinct foods, computes a
reference nutrient snapshot for each food, and writes a review CSV used by
downstream import planning.
"""

import csv
from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv


def _to_decimal(s: str) -> Decimal | None:
    try:
        return Decimal(s.strip())
    except (InvalidOperation, ValueError, AttributeError):
        return None


def _per_unit(nutrient: str, value: Decimal) -> Decimal | None:
    n = _to_decimal(nutrient)
    if n is not None and value != Decimal(0):
        return n / value
    return None


def _median(values: list[Decimal]) -> Decimal | None:
    if not values:
        return None
    return sorted(values)[len(values) // 2]


def _modal(values: list[str]) -> str:
    if not values:
        return ""
    return Counter(values).most_common(1)[0][0]


def load_existing_review(review_path: str | Path) -> dict[str, dict[str, str]]:
    """Load existing review rows keyed by description."""
    result: dict[str, dict[str, str]] = {}
    p = Path(review_path)
    if not p.exists():
        return result
    with open(p, newline="", encoding="utf-8-sig") as f:
        first_line = f.readline()
        if "description" not in first_line.lower():
            # Some helper files may still include the MFP title row.
            reader = csv.DictReader(f)
        else:
            f.seek(0)
            reader = csv.DictReader(f)
        for row in reader:
            desc = row.get("description", "").strip()
            if not desc:
                continue
            result[desc] = {
                "serving_mode": row.get("serving_mode", "").strip(),
                "current_serving_grams": row.get("current_serving_grams", "").strip(),
                "corrected_serving_grams": row.get("corrected_serving_grams", "").strip(),
                "confidence": row.get("confidence", "").strip(),
                "notes": row.get("notes", "").strip(),
            }
    return result


def _mode_for_units(existing_mode: str, units: set[str]) -> str:
    if existing_mode in {"mass", "volume", "serving_unit"}:
        return existing_mode
    if units <= {"g", "kg", "mg"}:
        return "mass"
    if units <= {"ml"}:
        return "volume"
    return "serving_unit"


def run(
    input_path: str | Path,
    output_path: str | Path,
    *,
    existing_review_path: str | Path | None = None,
) -> dict:
    input_path = Path(input_path)
    output_path = Path(output_path)

    _, rows = load_csv(input_path)
    food_rows = [r for r in rows if r.get("item_type") == "Foods"]

    groups: dict[str, list[dict]] = defaultdict(list)
    for r in food_rows:
        groups[r["description"]].append(r)

    existing = (
        load_existing_review(existing_review_path) if existing_review_path else {}
    )

    review_fields = [
        "description",
        "row_count",
        "serving_mode",
        "reference_basis",
        "reference_calories",
        "reference_protein_g",
        "reference_carbs_g",
        "reference_fat_g",
        "example_value",
        "example_unit",
        "example_serving",
        "current_serving_grams",
        "corrected_serving_grams",
        "confidence",
        "notes",
    ]

    review_rows: list[dict] = []
    mass_count = 0
    volume_count = 0
    serving_count = 0

    for desc, entries in sorted(groups.items()):
        units = {e.get("unit", "").strip() for e in entries}
        existing_row = existing.get(desc, {})
        serving_mode = _mode_for_units(existing_row.get("serving_mode", ""), units)
        if serving_mode == "mass":
            mass_count += 1
            reference_basis = "per_100g"
            multiplier = Decimal(100)
            current_serving_grams = existing_row.get("current_serving_grams") or "100"
        elif serving_mode == "volume":
            volume_count += 1
            reference_basis = "per_100ml"
            multiplier = Decimal(100)
            current_serving_grams = existing_row.get("current_serving_grams", "")
        else:
            serving_count += 1
            reference_basis = "per_serving"
            multiplier = Decimal(1)
            current_serving_grams = existing_row.get("current_serving_grams", "")

        cal_vals: list[Decimal] = []
        prot_vals: list[Decimal] = []
        carbs_vals: list[Decimal] = []
        fat_vals: list[Decimal] = []
        serving_strs: list[str] = []
        value_strs: list[str] = []
        unit_strs: list[str] = []

        for e in entries:
            v = _to_decimal(e.get("value", ""))
            if v is None or v == Decimal(0):
                continue
            cal = _per_unit(e.get("calories", ""), v)
            prot = _per_unit(e.get("protein_g", ""), v)
            carbs = _per_unit(e.get("carbs_g", ""), v)
            fat = _per_unit(e.get("fat_g", ""), v)
            if cal is not None:
                cal_vals.append(cal * multiplier)
            if prot is not None:
                prot_vals.append(prot * multiplier)
            if carbs is not None:
                carbs_vals.append(carbs * multiplier)
            if fat is not None:
                fat_vals.append(fat * multiplier)
            serving_strs.append(e.get("serving", ""))
            value_strs.append(e.get("value", ""))
            unit_strs.append(e.get("unit", ""))

        def _fmt(d: Decimal | None) -> str:
            if d is None:
                return ""
            d = d.quantize(Decimal("0.1"))
            if d == d.to_integral():
                return str(int(d))
            return f"{d:.1f}"

        review_rows.append({
            "description": desc,
            "row_count": str(len(entries)),
            "serving_mode": serving_mode,
            "reference_basis": reference_basis,
            "reference_calories": _fmt(_median(cal_vals)),
            "reference_protein_g": _fmt(_median(prot_vals)),
            "reference_carbs_g": _fmt(_median(carbs_vals)),
            "reference_fat_g": _fmt(_median(fat_vals)),
            "example_value": _modal(value_strs),
            "example_unit": _modal(unit_strs),
            "example_serving": _modal(serving_strs),
            "current_serving_grams": current_serving_grams,
            "corrected_serving_grams": existing_row.get("corrected_serving_grams", ""),
            "confidence": existing_row.get("confidence", ""),
            "notes": existing_row.get("notes", ""),
        })

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=review_fields)
        writer.writeheader()
        writer.writerows(review_rows)

    return {
        "total_foods": len(groups),
        "review_rows_written": len(review_rows),
        "mass_mode_count": mass_count,
        "volume_mode_count": volume_count,
        "serving_unit_mode_count": serving_count,
        "output_path": str(output_path),
    }
