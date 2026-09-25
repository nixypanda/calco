"""Step 2: Scale value column by serving number.

new_value = Decimal(value) x Decimal(parse_serving(serving).number)
"""

from decimal import Decimal, InvalidOperation
from pathlib import Path

from steps import load_csv, parse_serving, write_csv


def _fmt(d: Decimal) -> str:
    s = str(d)
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    rows_scaled = 0
    skipped_empty = 0
    skipped_zero = 0
    sample_before = ""
    sample_after = ""

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            continue

        serving = row.get("serving", "")
        number_str, _ = parse_serving(serving)

        if not number_str:
            skipped_empty += 1
            continue

        try:
            number = Decimal(number_str)
        except InvalidOperation:
            skipped_empty += 1
            continue

        if number == Decimal(0):
            skipped_zero += 1
            continue

        value = row.get("value", "0")
        new_value = Decimal(value) * number

        if rows_scaled == 0:
            sample_before = value
            sample_after = _fmt(new_value)

        row["value"] = _fmt(new_value)
        rows_scaled += 1

    write_csv(output_path, fieldnames, rows)

    return {
        "rows_scaled": rows_scaled,
        "skipped_empty_serving": skipped_empty,
        "skipped_zero_serving": skipped_zero,
        "sample_before": sample_before,
        "sample_after": sample_after,
    }
