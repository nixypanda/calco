import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))

from calco_import.fetch.off import OffIndices, _keep_off_row, has_gs1_india_prefix


class KeepOffRowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.indices = OffIndices(
            code=0,
            product=1,
            brands=2,
            categories=3,
            countries_tags=4,
            serving_qty=5,
            serving_size=6,
        )
        self.required_indices = [7, 8, 9, 10]

    def row(self, code: str, country_tags: str) -> list[str]:
        return [
            code,
            "Product",
            "Brand",
            "Category",
            country_tags,
            "",
            "",
            "100",
            "10",
            "20",
            "5",
        ]

    def test_keeps_exact_india_country_tag(self) -> None:
        row = self.row("1234567890123", "en:france,en:india")

        self.assertTrue(_keep_off_row(row, self.indices, self.required_indices))

    def test_keeps_890_prefix_without_india_country_tag(self) -> None:
        row = self.row("8901234567890", "en:united-states")

        self.assertTrue(_keep_off_row(row, self.indices, self.required_indices))

    def test_keeps_gtin_14_with_890_after_indicator_digit(self) -> None:
        row = self.row("18901234567890", "")

        self.assertTrue(_keep_off_row(row, self.indices, self.required_indices))

    def test_rejects_gtin_14_whose_indicator_and_prefix_start_with_890(self) -> None:
        row = self.row("89012345678901", "")

        self.assertFalse(_keep_off_row(row, self.indices, self.required_indices))

    def test_rejects_country_tag_that_only_contains_india_as_substring(self) -> None:
        row = self.row("1234567890123", "en:british-indian-ocean-territory")

        self.assertFalse(_keep_off_row(row, self.indices, self.required_indices))

    def test_rejects_candidate_with_missing_required_macro(self) -> None:
        row = self.row("8901234567890", "")
        row[self.required_indices[2]] = ""

        self.assertFalse(_keep_off_row(row, self.indices, self.required_indices))


class Gs1IndiaPrefixTests(unittest.TestCase):
    def test_rejects_non_numeric_off_identifier(self) -> None:
        self.assertFalse(has_gs1_india_prefix("890example"))


if __name__ == "__main__":
    unittest.main()
