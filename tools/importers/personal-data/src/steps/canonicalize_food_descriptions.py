"""Step 8: Canonicalize food descriptions for downstream review/import.

This makes a small set of deterministic description fixes explicit:

- relabel obvious misnamed rows
- expand the known combined egg row into two canonical foods

The expansion is intentional and changes row count. Keeping it here makes the
transformation reproducible and reviewable instead of relying on an ad hoc CSV.
"""

from pathlib import Path

from steps import load_csv, write_csv


RENAME_MAP = {
    "1 Hard Boiled": "Egg White",
    "Eggs, boiled": "Egg, boiled",
    "Homemade": "Kala Chana Masala",
}

COMBINED_EGG_DESCRIPTION = "5 Egg Whites and 1 Whole Egg"

EGG_WHITE_ROW = {
    "description": "Egg White",
    "serving": "1.0 Egg White",
    "value": "5",
    "unit": "serving",
    "calories": "85",
    "fat_g": "0.5",
    "saturated_fat_g": "0",
    "trans_fat_g": "0",
    "polyunsaturated_fat_g": "0",
    "monounsaturated_fat_g": "0",
    "cholesterol_mg": "55",
    "sodium_mg": "275",
    "carbs_g": "1",
    "fiber_g": "0",
    "sugar_g": "1",
    "protein_g": "18",
    "vitamin_d_pct_daily_value": "",
    "calcium_mg": "11.5",
    "iron_pct_daily_value": "0",
    "potassium_mg": "269",
    "vitamin_a_pct_daily_value": "0",
    "vitamin_c_pct_daily_value": "0",
    "is_pseudo_gram": "FALSE",
    "macro_mismatch": "FALSE",
}

BOILED_EGG_ROW = {
    "description": "Egg, boiled",
    "serving": "1.0 egg",
    "value": "1",
    "unit": "serving",
    "calories": "71.5",
    "fat_g": "4.755",
    "saturated_fat_g": "1.563",
    "trans_fat_g": "",
    "polyunsaturated_fat_g": "0.9555",
    "monounsaturated_fat_g": "1.829",
    "cholesterol_mg": "186.0",
    "sodium_mg": "71.0",
    "carbs_g": "0.36",
    "fiber_g": "0.0",
    "sugar_g": "0.185",
    "protein_g": "6.28",
    "vitamin_d_pct_daily_value": "10.0",
    "calcium_mg": "2.8",
    "iron_pct_daily_value": "4.86111",
    "potassium_mg": "69.0",
    "vitamin_a_pct_daily_value": "",
    "vitamin_c_pct_daily_value": "0.0",
    "is_pseudo_gram": "FALSE",
    "macro_mismatch": "FALSE",
}


def _copy_with_updates(row: dict[str, str], updates: dict[str, str]) -> dict[str, str]:
    out = dict(row)
    out.update(updates)
    return out


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    output_rows: list[dict[str, str]] = []
    rows_renamed = 0
    combined_rows_expanded = 0

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            output_rows.append(row)
            continue

        desc = row.get("description", "")

        if desc == COMBINED_EGG_DESCRIPTION:
            output_rows.append(_copy_with_updates(row, EGG_WHITE_ROW))
            output_rows.append(_copy_with_updates(row, BOILED_EGG_ROW))
            combined_rows_expanded += 1
            continue

        new_desc = RENAME_MAP.get(desc)
        if new_desc is not None:
            updated = dict(row)
            updated["description"] = new_desc
            output_rows.append(updated)
            rows_renamed += 1
            continue

        output_rows.append(row)

    write_csv(output_path, fieldnames, output_rows)

    return {
        "input_rows": len(rows),
        "output_rows": len(output_rows),
        "rows_renamed": rows_renamed,
        "combined_rows_expanded": combined_rows_expanded,
    }
