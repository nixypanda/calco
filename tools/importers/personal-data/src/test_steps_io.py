"""Tests for the shared CSV helpers used by the cleaning pipeline."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from steps import load_csv

MISSING_HEADER_MESSAGE = "missing CSV header row"


def _write(content: str) -> str:
    with tempfile.NamedTemporaryFile(
        "w", newline="", delete=False, suffix=".csv"
    ) as handle:
        handle.write(content)
        return handle.name


class LoadCsvTests(unittest.TestCase):
    def test_loads_title_row_and_header(self) -> None:
        path = _write("test export\na,b\n1,2\n")
        try:
            fieldnames, rows = load_csv(path)
        finally:
            Path(path).unlink()
        assert fieldnames == ["a", "b"]
        assert rows == [{"a": "1", "b": "2"}]

    def test_missing_header_raises(self) -> None:
        path = _write("sherubthakur Data Access Request\n")
        caught: ValueError | None = None
        try:
            load_csv(path)
        except ValueError as exc:
            caught = exc
        finally:
            Path(path).unlink()
        assert caught is not None
        assert MISSING_HEADER_MESSAGE in str(caught)


if __name__ == "__main__":
    unittest.main()
