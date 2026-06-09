"""Step 1: Normalize unit strings to canonical forms.

~55 unit variants → ~10 canonical forms.
"""

import re
from collections import Counter
from decimal import Decimal
from pathlib import Path

from steps import load_csv, write_csv

KG_FACTOR = Decimal(1000)

PAREN_RE = re.compile(r'\s*\([^)]*\)')
COMMA_ANNOTATION_RE = re.compile(r',\s*\w+(\s+\w+)*$')
KG_RE = re.compile(r'^kg\(?s?\)?$', re.IGNORECASE)

CANONICAL: dict[str, str] = {
    "g": "g",
    "gm": "g",
    "gram": "g",
    "grams": "g",
    "gram(s)": "g",
    "gms": "g",
    "gramme": "g",
    "ml": "ml",
    "cup": "cup",
    "cup cooked": "cup",
    "cups": "cup",
    "bowl": "bowl",
    "household bowl": "bowl",
    "plate": "bowl",
    "katori": "cup",
    "tbsp": "tbsp",
    "tbs": "tbsp",
    "tablespoon": "tbsp",
    "ounce": "oz",
    "oz": "oz",
}

OR_ANNOTATIONS: dict[str, str] = {
    "cup or 100g": "cup",
}


def _clean(unit: str) -> str:
    u = PAREN_RE.sub("", unit)
    u = COMMA_ANNOTATION_RE.sub("", u)
    return u.strip()


def _fmt(d: Decimal) -> str:
    s = str(d)
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def normalize(unit: str, value: str) -> tuple[str, str | None]:
    u = _clean(unit)
    if not u or u in ('"', "'", "1"):
        return ("", None)

    ul = u.lower()

    if KG_RE.match(ul):
        scaled = _fmt(Decimal(value) * KG_FACTOR)
        return ("g", scaled)

    if ul in OR_ANNOTATIONS:
        return (OR_ANNOTATIONS[ul], None)

    if ul in CANONICAL:
        return (CANONICAL[ul], None)

    return ("serving", None)


def run(input_path: str | Path, output_path: str | Path) -> dict:
    fieldnames, rows = load_csv(input_path)

    before: Counter = Counter()
    after: Counter = Counter()
    modified = 0
    kg_converted = 0

    for row in rows:
        if row.get("item_type", "").strip() != "Foods":
            continue

        orig_unit = row.get("unit", "")
        before[orig_unit] += 1

        new_unit, scaled = normalize(orig_unit, row.get("value", "0"))

        if new_unit != orig_unit:
            row["unit"] = new_unit
            modified += 1

        if scaled is not None:
            row["value"] = scaled
            kg_converted += 1

        after[new_unit] += 1

    write_csv(output_path, fieldnames, rows)

    return {
        "rows_modified": modified,
        "kg_to_gram_conversions": kg_converted,
        "canonical_counts": dict(sorted(after.items())),
    }
