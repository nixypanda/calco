"""Step 0: Merge meal + serving columns from mfp-data-fixed.csv into mfp-data.csv."""

from collections import defaultdict
from pathlib import Path

from steps import load_csv, write_csv


def run(
    raw_path: str | Path,
    fixed_path: str | Path,
    output_path: str | Path,
) -> dict:
    raw_path = Path(raw_path)
    fixed_path = Path(fixed_path)
    output_path = Path(output_path)

    raw_fieldnames, raw_rows = load_csv(raw_path)
    _, fixed_rows = load_csv(fixed_path)

    fixed_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in fixed_rows:
        fixed_groups[(r["date"], r["food"])].append(r)

    date_idx = raw_fieldnames.index("date")
    new_fieldnames = [
        *raw_fieldnames[: date_idx + 1],
        "meal",
        "serving",
        *raw_fieldnames[date_idx + 1 :],
    ]

    total_foods = 0
    matched = 0
    fixed_consumed: dict[tuple[str, str], int] = defaultdict(int)
    output_rows: list[dict] = []

    for r in raw_rows:
        is_food = r.get("item_type", "").strip() == "Foods"
        if is_food:
            total_foods += 1
            key = (r["date"], r["description"])
            frows = fixed_groups.get(key)
            if frows is None:
                r["meal"] = ""
                r["serving"] = ""
            else:
                matched += 1
                idx = fixed_consumed[key]
                if idx < len(frows):
                    fr = frows[idx]
                    fixed_consumed[key] += 1
                else:
                    fr = frows[-1]
                r["meal"] = fr.get("meal", "")
                r["serving"] = fr.get("serving", "")
        else:
            r["meal"] = ""
            r["serving"] = ""

        output_rows.append(r)

    write_csv(output_path, new_fieldnames, output_rows)

    fixed_keys = set(fixed_groups.keys())
    raw_food_keys = {
        (r["date"], r["description"])
        for r in raw_rows
        if r.get("item_type", "").strip() == "Foods"
    }

    return {
        "total_foods": total_foods,
        "matched": matched,
        "keys_in_both": len(raw_food_keys & fixed_keys),
        "output": str(output_path),
    }
