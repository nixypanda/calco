"""Step 7: Remove duplicate log entries.

After review, the 8 food groups with matching (date, meal, description, serving)
identified in the analysis fall into two categories:

  - 4 groups are truly identical rows (Paneer Paratha, Curd, Bread, Whole wheat
    bread) — export artifacts, stripped by this step.
  - 4 groups have conflicting values (multi-protein bread, AS Protein Bread,
    Punjabi Kadhi, White rice, cooked) — confirmed intentional entries where the
    user logged two different portions of the same food in the same meal. These
    are left untouched.

The CSV has an unnamed row-index column (fieldname ``) that differs for every row,
so it is excluded from the dedup comparison.
"""

from pathlib import Path

from steps import load_csv, write_csv


def _signature(row: dict) -> tuple:
    """Build dedup key excluding the unnamed row-index column."""
    return tuple(v for k, v in row.items() if k)


def run(input_path: str | Path, output_path: str | Path) -> dict:
    input_path = Path(input_path)
    output_path = Path(output_path)

    fieldnames, rows = load_csv(input_path)

    seen: set[tuple] = set()
    kept: list[dict] = []
    duplicate_count = 0

    for r in rows:
        sig = _signature(r)
        if sig in seen:
            duplicate_count += 1
            continue
        seen.add(sig)
        kept.append(r)

    write_csv(output_path, fieldnames, kept)

    return {
        "input_rows": len(rows),
        "output_rows": len(kept),
        "duplicates_removed": duplicate_count,
    }
