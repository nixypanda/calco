import json
import re
from collections.abc import Mapping
from typing import TextIO, cast

JsonRow = dict[str, object]

_RE_VALUE_ERROR = re.compile(r"^([\d.]+)\s*±")


def write_jsonl_row(out: TextIO, row: Mapping[str, object]) -> None:
    out.write(json.dumps(row, ensure_ascii=False) + "\n")


def normalize_categories(row: JsonRow) -> JsonRow:
    values: list[object] = []
    raw_categories = row.get("categories")
    if isinstance(raw_categories, list):
        values.extend(raw_categories)
    elif raw_categories:
        values.append(raw_categories)
    raw_category = row.get("category")
    if raw_category:
        values.append(raw_category)
    normalized: list[str] = []
    for v in values:
        for part in str(v).split(","):
            category = part.strip().lower()
            if category and category not in normalized:
                normalized.append(category)
    row["categories"] = normalized
    row.pop("category", None)
    return row


def parse_amount(value: str | int | float | None) -> float | None:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        if not value or value in ("-", "NA", "n/a"):
            return None
        m = _RE_VALUE_ERROR.match(value)
        if m:
            value = m.group(1)
    try:
        return round(float(value), 6)
    except (ValueError, TypeError):
        return None


def load_jsonl(
    filepath: str,
) -> tuple[list[JsonRow], list[JsonRow], list[JsonRow]]:
    foods: list[JsonRow] = []
    nutrients: list[JsonRow] = []
    servings: list[JsonRow] = []
    with open(filepath, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            obj = cast("JsonRow", json.loads(line))
            row = {k: v for k, v in obj.items() if k != "type"}
            t = obj.get("type")
            if t == "food":
                row = normalize_categories(row)
                foods.append(row)
            elif t == "nutrient":
                nutrients.append(row)
            elif t == "serving":
                servings.append(row)
    return foods, nutrients, servings


def load_jsonl_rows(
    filepath: str,
) -> list[JsonRow]:
    rows: list[JsonRow] = []
    with open(filepath, encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            rows.append(cast("JsonRow", json.loads(line)))
    return rows
