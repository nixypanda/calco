"""Step 3: Flag rows where g is used as a pseudo-unit (not real grams).

Pseudo-gram entries have serving_number ≈ 1.0 and unit=g with unreasonably
high calories for 1g of food. The value field IS the actual gram amount.

Outputs a review CSV alongside the main cleaned CSV.
"""

import csv
from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv, parse_serving, write_csv

REVIEW_HEADER = [
    "description",
    "date",
    "meal",
    "value_g",
    "calories",
    "cal_per_100g",
    "outside_range",
]

CAL_PER_100G_LOW = Decimal(30)
CAL_PER_100G_HIGH = Decimal(500)
PSEUDO_GRAM_CALORIE_FLOOR = Decimal(30)


def _fmt(d: Decimal) -> str:
    s = str(d)
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    flagged: list[dict] = []
    total_flagged = 0
    outside_range = 0

    new_fieldnames = list(fieldnames)
    if "is_pseudo_gram" not in new_fieldnames:
        new_fieldnames.append("is_pseudo_gram")

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            row["is_pseudo_gram"] = "FALSE"
            continue

        unit = row.get("unit", "").strip()
        if unit != "g":
            row["is_pseudo_gram"] = "FALSE"
            continue

        num_str, _ = parse_serving(row.get("serving", ""))
        if not num_str:
            row["is_pseudo_gram"] = "FALSE"
            continue

        try:
            number = Decimal(num_str)
        except InvalidOperation:
            row["is_pseudo_gram"] = "FALSE"
            continue

        if number != Decimal("1.0"):
            row["is_pseudo_gram"] = "FALSE"
            continue

        cal_str = row.get("calories", "0").strip()
        try:
            cal = Decimal(cal_str) if cal_str else Decimal(0)
        except InvalidOperation:
            cal = Decimal(0)

        if cal <= PSEUDO_GRAM_CALORIE_FLOOR:
            row["is_pseudo_gram"] = "FALSE"
            continue

        row["is_pseudo_gram"] = "TRUE"
        total_flagged += 1

        val_str = row.get("value", "0").strip()
        try:
            value_g = Decimal(val_str) if val_str else Decimal(0)
        except InvalidOperation:
            value_g = Decimal(0)

        cal_per_100g = (cal / value_g * 100) if value_g != 0 else Decimal(0)
        is_outside = cal_per_100g < CAL_PER_100G_LOW or cal_per_100g > CAL_PER_100G_HIGH
        if is_outside:
            outside_range += 1

        flagged.append({
            "description": row.get("description", ""),
            "date": row.get("date", ""),
            "meal": row.get("meal", ""),
            "value_g": _fmt(value_g),
            "calories": _fmt(cal),
            "cal_per_100g": _fmt(cal_per_100g),
            "outside_range": "YES" if is_outside else "NO",
        })

    write_csv(output_path, new_fieldnames, rows)

    output_dir = Path(output_path).parent
    review_path = output_dir / "step-3-review-pseudo-grams.csv"
    with open(review_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=REVIEW_HEADER)
        writer.writeheader()
        writer.writerows(flagged)

    return {
        "total_flagged": total_flagged,
        "outside_30_500_range": outside_range,
        "review_file": str(review_path),
    }
