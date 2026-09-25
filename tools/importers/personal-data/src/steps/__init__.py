"""Shared utilities for MFP data cleaning pipeline."""

import csv
import re
from pathlib import Path

TITLE_ROW = "sherubthakur Data Access Request"

SERVING_RE = re.compile(r"^([\d.]+)\s*(.*)")


def load_csv(path: str | Path) -> tuple[list[str], list[dict]]:
    """Load MFP CSV with a title row.

    Returns (fieldnames, list of row dicts).
    The title row is consumed and discarded.
    """
    with open(path, newline="", encoding="utf-8-sig") as f:
        f.readline()
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            msg = f"{path}: missing CSV header row"
            raise ValueError(msg)
        fieldnames = list(reader.fieldnames)
        rows = list(reader)
    return fieldnames, rows


def write_csv(path: str | Path, fieldnames: list[str], rows: list[dict]) -> None:
    """Write MFP CSV with title row and header."""
    with open(path, "w", newline="", encoding="utf-8") as f:
        f.write(TITLE_ROW + "," * (len(fieldnames) - 1) + "\n")
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def step_path(data_dir: Path, n: int, name: str) -> Path:
    """Return the output path for step n: <data_dir>/step-<n>-out-<name>.csv"""
    return data_dir / f"step-{n}-out-{name}.csv"


def parse_serving(serving: str) -> tuple[str, str]:
    """Split a serving string '<number> <unit>' into (number, unit).

    Returns ('', '') if empty, (number, unit) otherwise.
    """
    s = serving.strip()
    if not s:
        return "", ""
    m = SERVING_RE.match(s)
    if m:
        return m.group(1), m.group(2).strip()
    return s, ""
