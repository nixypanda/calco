"""Shared MFP nutrient mapping and conversion helpers."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation

PERCENT = Decimal(100)


@dataclass(frozen=True)
class MfpNutrientMapping:
    """Map one MFP source column into one CalCo nutrient code."""

    source_column: str
    nutrient_code: str
    review_column: str
    daily_value: Decimal | None = None

    @property
    def reference_column(self) -> str:
        return self.review_column

    @property
    def daily_value_amount(self) -> Decimal | None:
        return self.daily_value


# Backwards-compatible name used by the numbered pipeline steps.
MfpNutrientSpec = MfpNutrientMapping


MFP_NUTRIENT_MAPPINGS = (
    MfpNutrientMapping("calories", "ENERGY_KCAL", "reference_calories"),
    MfpNutrientMapping("protein_g", "PROTEIN_G", "reference_protein_g"),
    MfpNutrientMapping("carbs_g", "CARBS_G", "reference_carbs_g"),
    MfpNutrientMapping("fat_g", "FAT_G", "reference_fat_g"),
    MfpNutrientMapping("fiber_g", "FIBER_G", "reference_fiber_g"),
    MfpNutrientMapping("sugar_g", "SUGAR_G", "reference_sugar_g"),
    MfpNutrientMapping(
        "saturated_fat_g",
        "SATURATED_FAT_G",
        "reference_saturated_fat_g",
    ),
    MfpNutrientMapping("trans_fat_g", "TRANS_FAT_G", "reference_trans_fat_g"),
    MfpNutrientMapping(
        "monounsaturated_fat_g",
        "MONOUNSATURATED_FAT_G",
        "reference_monounsaturated_fat_g",
    ),
    MfpNutrientMapping(
        "polyunsaturated_fat_g",
        "POLYUNSATURATED_FAT_G",
        "reference_polyunsaturated_fat_g",
    ),
    MfpNutrientMapping("cholesterol_mg", "CHOLESTEROL_MG", "reference_cholesterol_mg"),
    MfpNutrientMapping("sodium_mg", "SODIUM_MG", "reference_sodium_mg"),
    MfpNutrientMapping("calcium_mg", "CALCIUM_MG", "reference_calcium_mg"),
    MfpNutrientMapping("potassium_mg", "POTASSIUM_MG", "reference_potassium_mg"),
    MfpNutrientMapping(
        "vitamin_d_pct_daily_value",
        "VITAMIN_D_UG",
        "reference_vitamin_d_ug",
        daily_value=Decimal(20),
    ),
    MfpNutrientMapping(
        "iron_pct_daily_value",
        "IRON_MG",
        "reference_iron_mg",
        daily_value=Decimal(18),
    ),
    MfpNutrientMapping(
        "vitamin_a_pct_daily_value",
        "VITAMIN_A_UG",
        "reference_vitamin_a_ug",
        daily_value=Decimal(900),
    ),
    MfpNutrientMapping(
        "vitamin_c_pct_daily_value",
        "VITAMIN_C_MG",
        "reference_vitamin_c_mg",
        daily_value=Decimal(90),
    ),
)

REQUIRED_MACRO_CODES = ("ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G")
MACRO_NUTRIENT_SPECS = MFP_NUTRIENT_MAPPINGS[:4]
MFP_NUTRIENT_SPECS = MFP_NUTRIENT_MAPPINGS
REQUIRED_REVIEW_REFERENCE_COLUMNS = tuple(
    mapping.review_column for mapping in MFP_NUTRIENT_MAPPINGS
)


def parse_mfp_decimal(value: str) -> Decimal | None:
    """Parse an MFP number or percent string into Decimal."""

    text = value.strip()
    if not text:
        return None
    if text.endswith("%"):
        text = text[:-1].strip()
    try:
        return Decimal(text)
    except InvalidOperation as exc:
        message = f"Invalid numeric value: {value!r}"
        raise ValueError(message) from exc


def parse_decimal(value: str | None) -> Decimal | None:
    """Parse a decimal-like string, returning None for blanks and bad values."""

    if value is None:
        return None
    try:
        return parse_mfp_decimal(value)
    except ValueError:
        return None


def convert_source_value(mapping: MfpNutrientMapping, value: str) -> Decimal | None:
    """Convert one raw MFP source value into the CalCo absolute amount."""

    parsed = parse_mfp_decimal(value)
    if parsed is None:
        return None
    if mapping.daily_value is None:
        return parsed
    return (parsed * mapping.daily_value) / PERCENT


def parse_mfp_nutrient_amount(
    row: dict[str, str],
    mapping: MfpNutrientMapping,
) -> Decimal | None:
    """Read and convert one mapped nutrient from an MFP row."""

    return convert_source_value(mapping, row.get(mapping.source_column, ""))
