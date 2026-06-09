"""Step 4: Check calories against macro formula.

Flags rows where stated calories differ from the sum of macros
(protein×4 + carbs×4 + fat×9) by more than 20%.

Resolution: Trust stated calories as more reliable. This step is
for reporting/review only.
"""

import csv
from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv, write_csv

MISMATCH_THRESHOLD = Decimal("20")  # percent
REVIEW_HEADER = [
    "description",
    "date",
    "meal",
    "calories",
    "macro_cal",
    "diff_pct",
    "fat_g",
    "carbs_g",
    "protein_g",
]


def _fmt(d: Decimal) -> str:
    s = str(d)
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def _dec(val: str) -> Decimal | None:
    v = val.strip()
    if not v:
        return None
    try:
        return Decimal(v)
    except InvalidOperation:
        return None


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    mismatches: list[dict] = []
    checked = 0
    total = 0

    new_fieldnames = list(fieldnames)
    if "macro_mismatch" not in new_fieldnames:
        new_fieldnames.append("macro_mismatch")

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            row["macro_mismatch"] = "FALSE"
            continue

        total += 1
        cal = _dec(row.get("calories", ""))
        fat = _dec(row.get("fat_g", ""))
        carbs = _dec(row.get("carbs_g", ""))
        prot = _dec(row.get("protein_g", ""))

        if cal is None or fat is None or carbs is None or prot is None:
            row["macro_mismatch"] = "SKIP"
            continue

        checked += 1
        macro_cal = prot * 4 + carbs * 4 + fat * 9

        if cal == 0:
            row["macro_mismatch"] = "FALSE"
            continue

        diff_pct = abs(macro_cal - cal) / cal * 100

        if diff_pct > MISMATCH_THRESHOLD:
            row["macro_mismatch"] = "TRUE"
            mismatches.append({
                "description": row.get("description", ""),
                "date": row.get("date", ""),
                "meal": row.get("meal", ""),
                "calories": _fmt(cal),
                "macro_cal": _fmt(macro_cal),
                "diff_pct": f"{diff_pct:.1f}",
                "fat_g": _fmt(fat),
                "carbs_g": _fmt(carbs),
                "protein_g": _fmt(prot),
            })
        else:
            row["macro_mismatch"] = "FALSE"

    write_csv(output_path, new_fieldnames, rows)

    output_dir = Path(output_path).parent
    review_path = output_dir / "step-4-review-macro-mismatch.csv"
    with open(review_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=REVIEW_HEADER)
        writer.writeheader()
        writer.writerows(mismatches)

    return {
        "total_food_rows": total,
        "checked": checked,
        "mismatches": len(mismatches),
        "max_diff_pct": max((float(r["diff_pct"]) for r in mismatches), default=0.0),
        "review_file": str(review_path),
    }
