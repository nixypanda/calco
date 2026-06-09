import argparse
import csv
import hashlib
import json
import logging
import os
import re
import sys
from collections import Counter, defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any, cast

import requests
from rapidfuzz import fuzz

DEFAULT_API_URL = "http://localhost:3001/api"
DEFAULT_INPUT = os.path.join(os.path.dirname(__file__), "apps", "mfp-data.csv")
DEFAULT_REVIEW = os.path.join(os.path.dirname(__file__), "apps", "mfp-food-review.csv")
DEFAULT_MAP = os.path.join(os.path.dirname(__file__), "apps", "mfp-food-map.json")
DEFAULT_MISMATCH_REPORT = os.path.join(
    os.path.dirname(__file__), "apps", "mfp-history-mismatches.csv"
)

MFP_FINGERPRINT_PREFIX = "mfp_row="
CALORIE_TOLERANCE = Decimal(5)
MACRO_TOLERANCE = Decimal(2)
SEARCH_ACCEPT_SCORE = 92

log = logging.getLogger("mfp-import")

NUTRIENT_COLUMNS = {
    "calories": "ENERGY_KCAL",
    "fat_g": "FAT_G",
    "saturated_fat_g": "SATURATED_FAT_G",
    "trans_fat_g": "TRANS_FAT_G",
    "polyunsaturated_fat_g": "POLYUNSATURATED_FAT_G",
    "monounsaturated_fat_g": "MONOUNSATURATED_FAT_G",
    "cholesterol_mg": "CHOLESTEROL_MG",
    "sodium_mg": "SODIUM_MG",
    "carbs_g": "CARBS_G",
    "fiber_g": "FIBER_G",
    "sugar_g": "SUGAR_G",
    "protein_g": "PROTEIN_G",
    "calcium_mg": "CALCIUM_MG",
    "potassium_mg": "POTASSIUM_MG",
}

UNSUPPORTED_NUTRIENT_COLUMNS = [
    "added_sugar_g",
    "sugar_alcohols_g",
    "vitamin_d_pct_daily_value",
    "iron_pct_daily_value",
    "vitamin_a_pct_daily_value",
    "vitamin_c_pct_daily_value",
]

REVIEW_COLUMNS = [
    "mfp_food_key",
    "description",
    "normalized_description",
    "row_count",
    "observed_units",
    "observed_quantities",
    "example_quantity",
    "example_unit",
    "example_calories",
    "example_protein_g",
    "example_carbs_g",
    "example_fat_g",
    "suggested_action",
    "approved",
    "matched_product_id",
    "matched_product_name",
    "match_score",
    "canonical_name",
    "serving_mode",
    "serving_unit",
    "serving_grams",
    "notes",
]

MAP_VERSION = 1


@dataclass(frozen=True)
class MfpFoodRow:
    row_number: int
    date: str
    description: str
    normalized_description: str
    value: Decimal
    unit: str
    normalized_unit: str
    nutrients: dict[str, Decimal]

    @property
    def food_key(self) -> str:
        digest = hashlib.sha1(self.normalized_description.encode()).hexdigest()[:12]
        return f"mfp:{digest}"


@dataclass(frozen=True)
class ReviewRow:
    food_key: str
    description: str
    normalized_description: str
    action: str
    approved: bool
    matched_product_id: str
    canonical_name: str
    serving_mode: str
    serving_unit: str
    serving_grams: Decimal | None
    notes: str


class ApiClient:
    def __init__(self, api_url: str, session_token: str) -> None:
        self.api_url = api_url.rstrip("/")
        self.session = requests.Session()
        self.headers = {"Content-Type": "application/json"}
        if session_token:
            self.headers["Cookie"] = f"calco_session={session_token}"

    def get(self, path: str, params: Mapping[str, str] | None = None) -> dict[str, Any]:
        response = self.session.get(
            f"{self.api_url}{path}", params=params, headers=self.headers, timeout=30
        )
        response.raise_for_status()
        return cast("dict[str, Any]", response.json())

    def post(self, path: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        response = self.session.post(
            f"{self.api_url}{path}", json=payload, headers=self.headers, timeout=30
        )
        response.raise_for_status()
        if not response.content:
            return {}
        return cast("dict[str, Any]", response.json())

    def search_foods(self, query: str) -> list[dict[str, Any]]:
        return cast(
            "list[dict[str, Any]]", self.get("/foods/search", {"q": query})["items"]
        )

    def get_food(self, product_id: str) -> dict[str, Any]:
        return self.get(f"/foods/{product_id}")

    def create_food(self, payload: Mapping[str, Any]) -> str:
        result = self.post("/foods/custom", payload)
        return str(result["id"])

    def create_log(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        return self.post("/logs", payload)

    def list_logs(self, date: str) -> list[dict[str, Any]]:
        return cast(
            "list[dict[str, Any]]",
            self.get("/logs", {"from": date, "to": date})["items"],
        )


def decimal_or_none(raw: str | None) -> Decimal | None:
    if raw is None:
        return None
    value = raw.strip()
    if not value:
        return None
    try:
        return Decimal(value)
    except InvalidOperation:
        return None


def decimal_to_str(value: Decimal | None) -> str:
    if value is None:
        return ""
    quantized = value.quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
    return format(quantized.normalize(), "f")


def normalize_description(value: str) -> str:
    normalized = value.strip().lower()
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized.replace("\u2019", "'")


def normalize_unit(value: str) -> str:
    raw = value.strip()
    lower = raw.lower()
    aliases = {
        "gram": "g",
        "grams": "g",
        "gram(s)": "g",
        "gm": "g",
        "gms": "g",
        "kgs": "kg",
        "kg(s)": "kg",
        "kilogram": "kg",
        "kilograms": "kg",
        "millilitre": "ml",
        "milliliter": "ml",
        "millilitres": "ml",
        "milliliters": "ml",
        "piese": "piece",
        "pieces": "piece",
    }
    return aliases.get(lower, raw)


def load_mfp_food_rows(path: str) -> tuple[list[MfpFoodRow], Counter[str]]:
    rows: list[MfpFoodRow] = []
    item_types: Counter[str] = Counter()
    with open(path, newline="", encoding="utf-8") as csv_file:
        reader = csv.reader(csv_file)
        try:
            next(reader)
            header = next(reader)
        except StopIteration as exc:
            msg = "MFP CSV must contain a title row and a header row"
            raise ValueError(msg) from exc

        for line_number, raw_row in enumerate(reader, start=3):
            record = dict(zip(header, raw_row, strict=False))
            item_type = (record.get("item_type") or "").strip()
            item_types[item_type] += 1
            if item_type != "Foods":
                continue

            description = (record.get("description") or "").strip()
            value = decimal_or_none(record.get("value"))
            date = (record.get("date") or "").strip()
            if not description or value is None or value <= 0 or not date:
                log.warning("Skipping invalid food row %d", line_number)
                continue

            nutrients = {
                code: amount
                for column, code in NUTRIENT_COLUMNS.items()
                if (amount := decimal_or_none(record.get(column))) is not None
            }
            if not nutrients:
                log.warning(
                    "Skipping food row %d with no supported nutrients", line_number
                )
                continue

            unit = (record.get("unit") or "").strip()
            rows.append(
                MfpFoodRow(
                    row_number=line_number,
                    date=date,
                    description=description,
                    normalized_description=normalize_description(description),
                    value=value,
                    unit=unit,
                    normalized_unit=normalize_unit(unit),
                    nutrients=nutrients,
                )
            )
    return rows, item_types


def group_foods(rows: Iterable[MfpFoodRow]) -> dict[str, list[MfpFoodRow]]:
    grouped: dict[str, list[MfpFoodRow]] = defaultdict(list)
    for row in rows:
        grouped[row.food_key].append(row)
    return dict(grouped)


def representative(rows: Sequence[MfpFoodRow]) -> MfpFoodRow:
    return max(
        rows, key=lambda row: (row.normalized_unit in {"g", "kg"}, len(row.nutrients))
    )


def values_for_review(rows: Sequence[MfpFoodRow]) -> dict[str, str]:
    units = Counter(row.normalized_unit or row.unit for row in rows)
    quantities = Counter(
        f"{decimal_to_str(row.value)} {row.normalized_unit or row.unit}" for row in rows
    )
    example = representative(rows)
    return {
        "observed_units": "; ".join(
            f"{unit}:{count}" for unit, count in units.most_common()
        ),
        "observed_quantities": "; ".join(
            f"{quantity}:{count}" for quantity, count in quantities.most_common(12)
        ),
        "example_quantity": decimal_to_str(example.value),
        "example_unit": example.normalized_unit or example.unit,
        "example_calories": decimal_to_str(example.nutrients.get("ENERGY_KCAL")),
        "example_protein_g": decimal_to_str(example.nutrients.get("PROTEIN_G")),
        "example_carbs_g": decimal_to_str(example.nutrients.get("CARBS_G")),
        "example_fat_g": decimal_to_str(example.nutrients.get("FAT_G")),
    }


def nutrient_amount(product: Mapping[str, Any], code: str) -> Decimal | None:
    for nutrient in cast("Sequence[Mapping[str, Any]]", product.get("nutrients", [])):
        if nutrient.get("code") == code:
            return decimal_or_none(str(nutrient.get("amount_per_100g", "")))
    return None


def energy_compatible(example: MfpFoodRow, product: Mapping[str, Any]) -> bool:
    energy = nutrient_amount(product, "ENERGY_KCAL")
    if energy is None:
        return True
    example_energy = example.nutrients.get("ENERGY_KCAL")
    if example_energy is None:
        return True
    per_100g = inferred_per_100g(example, "ENERGY_KCAL")
    if per_100g is None:
        return True
    return abs(energy - per_100g) <= Decimal(30)


def best_match(
    client: ApiClient | None, description: str, example: MfpFoodRow
) -> tuple[str, str, int]:
    if client is None:
        return "", "", 0
    try:
        candidates = client.search_foods(description)
    except requests.RequestException as exc:
        log.warning("Search failed for %r: %s", description, exc)
        return "", "", 0

    best: tuple[str, str, int] = ("", "", 0)
    for candidate in candidates[:10]:
        name = str(candidate.get("name", ""))
        score = fuzz.token_set_ratio(description, name)
        if score <= best[2]:
            continue
        try:
            detail = client.get_food(str(candidate["id"]))
        except requests.RequestException:
            continue
        if not energy_compatible(example, detail):
            continue
        best = (str(candidate["id"]), name, int(score))
    return best


def inferred_per_100g(row: MfpFoodRow, nutrient_code: str) -> Decimal | None:
    amount = row.nutrients.get(nutrient_code)
    if amount is None:
        return None
    grams = quantity_to_grams(row.value, row.normalized_unit)
    if grams is None or grams <= 0:
        return None
    return amount * Decimal(100) / grams


def quantity_to_grams(value: Decimal, unit: str) -> Decimal | None:
    if unit == "g":
        return value
    if unit == "kg":
        return value * Decimal(1000)
    if unit == "mg":
        return value / Decimal(1000)
    return None


def suggested_serving_mode(rows: Sequence[MfpFoodRow]) -> str:
    units = {row.normalized_unit for row in rows}
    if units and units <= {"g", "kg", "mg"}:
        return "mass"
    if units & {"g", "kg", "mg"}:
        return "manual"
    return "serving_unit"


def review_flags(rows: Sequence[MfpFoodRow], serving_mode: str) -> tuple[bool, str]:
    if serving_mode == "manual":
        return False, "mixed mass and non-mass units; review serving mode"
    if serving_mode == "mass":
        example = representative(rows)
        energy = inferred_per_100g(example, "ENERGY_KCAL")
        if energy is not None and energy > Decimal(1200):
            return (
                False,
                "mass unit looks suspicious; MFP may be using it as a serving unit",
            )
    return True, ""


def write_food_review(args: argparse.Namespace) -> None:
    client = ApiClient(args.api_url, args.session_token) if args.session_token else None
    rows, item_types = load_mfp_food_rows(args.input)
    grouped = group_foods(rows)
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)

    with open(args.output, "w", newline="", encoding="utf-8") as out_file:
        writer = csv.DictWriter(out_file, fieldnames=REVIEW_COLUMNS)
        writer.writeheader()
        for food_key, food_rows in sorted(
            grouped.items(),
            key=lambda item: representative(item[1]).description.lower(),
        ):
            example = representative(food_rows)
            matched_id, matched_name, match_score = best_match(
                client, example.description, example
            )
            suggested_action = (
                "match"
                if matched_id and match_score >= SEARCH_ACCEPT_SCORE
                else "create"
            )
            review_values = values_for_review(food_rows)
            serving_mode = suggested_serving_mode(food_rows)
            approved, notes = review_flags(food_rows, serving_mode)
            writer.writerow(
                {
                    "mfp_food_key": food_key,
                    "description": example.description,
                    "normalized_description": example.normalized_description,
                    "row_count": len(food_rows),
                    **review_values,
                    "suggested_action": suggested_action,
                    "approved": (
                        "yes"
                        if approved and suggested_action in {"match", "create"}
                        else "no"
                    ),
                    "matched_product_id": matched_id,
                    "matched_product_name": matched_name,
                    "match_score": match_score or "",
                    "canonical_name": example.description,
                    "serving_mode": serving_mode,
                    "serving_unit": (
                        review_values["example_unit"] if serving_mode != "mass" else ""
                    ),
                    "serving_grams": "100" if serving_mode != "mass" else "",
                    "notes": notes,
                }
            )

    log.info("Wrote %d food review rows to %s", len(grouped), args.output)
    log.info("Input item types: %s", dict(item_types))
    log.info(
        "Unsupported nutrient columns ignored: %s",
        ", ".join(UNSUPPORTED_NUTRIENT_COLUMNS),
    )


def read_review(path: str) -> dict[str, ReviewRow]:
    rows: dict[str, ReviewRow] = {}
    with open(path, newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        for line_number, row in enumerate(reader, start=2):
            food_key = (row.get("mfp_food_key") or "").strip()
            if not food_key:
                msg = f"missing mfp_food_key on review row {line_number}"
                raise ValueError(msg)
            action = (row.get("suggested_action") or "").strip().lower()
            if action not in {"match", "create", "skip"}:
                msg = f"invalid action {action!r} on review row {line_number}"
                raise ValueError(msg)
            approved = (row.get("approved") or "").strip().lower() in {
                "yes",
                "y",
                "true",
                "1",
            }
            serving_grams = decimal_or_none(row.get("serving_grams"))
            rows[food_key] = ReviewRow(
                food_key=food_key,
                description=(row.get("description") or "").strip(),
                normalized_description=(
                    row.get("normalized_description") or ""
                ).strip(),
                action=action,
                approved=approved,
                matched_product_id=(row.get("matched_product_id") or "").strip(),
                canonical_name=(row.get("canonical_name") or "").strip(),
                serving_mode=(row.get("serving_mode") or "").strip().lower(),
                serving_unit=(row.get("serving_unit") or "").strip(),
                serving_grams=serving_grams,
                notes=(row.get("notes") or "").strip(),
            )
    return rows


def nutrient_payload_for_row(
    row: MfpFoodRow, mode: str, serving_grams: Decimal | None = None
) -> list[dict[str, str]]:
    payload: list[dict[str, str]] = []
    for code, amount in sorted(row.nutrients.items()):
        if mode == "mass":
            per_100g = inferred_per_100g(row, code)
            if per_100g is None:
                continue
        else:
            grams = row.value * (serving_grams or Decimal(100))
            if grams <= 0:
                continue
            per_100g = amount * Decimal(100) / grams
        payload.append(
            {
                "code": code,
                "amount_per_100g": decimal_to_str(per_100g),
                "source": "MFP",
                "confidence": "unknown",
            }
        )
    return payload


def create_food_payload(review: ReviewRow, source_row: MfpFoodRow) -> dict[str, Any]:
    mode = review.serving_mode or suggested_serving_mode([source_row])
    if mode == "manual":
        msg = (
            f"{review.food_key} still has serving_mode=manual; "
            "edit review CSV before commit"
        )
        raise ValueError(msg)
    canonical_name = review.canonical_name or source_row.description
    nutrients = nutrient_payload_for_row(source_row, mode, review.serving_grams)
    if not nutrients:
        msg = f"cannot create food {canonical_name!r}; no usable nutrients"
        raise ValueError(msg)

    payload: dict[str, Any] = {
        "name": canonical_name,
        "brand": "MyFitnessPal",
        "categories": ["mfp-import"],
        "nutrients": nutrients,
        "servings": [],
    }
    if mode == "mass":
        servings = []
        if review.serving_unit and review.serving_grams and review.serving_grams > 0:
            servings.append(
                {
                    "label": f"1 {review.serving_unit}",
                    "quantity": "1",
                    "unit": review.serving_unit,
                    "grams": decimal_to_str(review.serving_grams),
                }
            )
        payload.update(
            {
                "serving_size_g": "100",
                "default_quantity": "100",
                "default_unit": "g",
                "servings": servings,
            }
        )
    else:
        unit = review.serving_unit or source_row.normalized_unit or "serving"
        grams = review.serving_grams or Decimal(100)
        payload.update(
            {
                "serving_size_g": decimal_to_str(grams),
                "default_quantity": "1",
                "default_unit": unit,
                "servings": [
                    {
                        "label": f"1 {unit}",
                        "quantity": "1",
                        "unit": unit,
                        "grams": decimal_to_str(grams),
                    }
                ],
            }
        )
    return payload


def write_food_map(args: argparse.Namespace) -> None:
    client = ApiClient(args.api_url, args.session_token)
    mfp_rows, _ = load_mfp_food_rows(args.input)
    grouped = group_foods(mfp_rows)
    review_rows = read_review(args.review)
    resolved: dict[str, dict[str, Any]] = {}
    skipped: list[str] = []

    for food_key, review in sorted(review_rows.items()):
        food_rows = grouped.get(food_key)
        if not food_rows:
            skipped.append(f"{food_key}: no matching source rows")
            continue
        if review.action == "skip" or not review.approved:
            skipped.append(f"{food_key}: skipped or not approved")
            continue
        if review.action == "match":
            if not review.matched_product_id:
                msg = f"{food_key} is marked match but has no matched_product_id"
                raise ValueError(msg)
            product = client.get_food(review.matched_product_id)
            product_id = str(product["id"])
        else:
            product_id = client.create_food(
                create_food_payload(review, representative(food_rows))
            )

        resolved[food_key] = {
            "product_id": product_id,
            "action": review.action,
            "description": review.description,
            "normalized_description": review.normalized_description,
            "serving_mode": review.serving_mode,
            "serving_unit": review.serving_unit,
        }

    output = {
        "version": MAP_VERSION,
        "source_csv": os.path.abspath(args.input),
        "review_csv": os.path.abspath(args.review),
        "foods": resolved,
        "skipped": skipped,
    }
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as out_file:
        json.dump(output, out_file, indent=2, sort_keys=True)
    log.info("Resolved %d foods into %s", len(resolved), args.output)
    if skipped:
        log.info("Skipped %d review rows", len(skipped))


def load_food_map(path: str) -> dict[str, dict[str, Any]]:
    with open(path, encoding="utf-8") as map_file:
        payload = cast("dict[str, Any]", json.load(map_file))
    if payload.get("version") != MAP_VERSION:
        msg = f"unsupported food map version: {payload.get('version')}"
        raise ValueError(msg)
    return cast("dict[str, dict[str, Any]]", payload.get("foods", {}))


def row_fingerprint(row: MfpFoodRow) -> str:
    parts = [
        row.date,
        row.normalized_description,
        decimal_to_str(row.value),
        row.normalized_unit,
        *(
            f"{code}:{decimal_to_str(value)}"
            for code, value in sorted(row.nutrients.items())
        ),
    ]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:20]


def existing_fingerprints(client: ApiClient, date: str) -> set[str]:
    fingerprints: set[str] = set()
    for item in client.list_logs(date):
        notes = str(item.get("notes") or "")
        for token in notes.split():
            if token.startswith(MFP_FINGERPRINT_PREFIX):
                fingerprints.add(token.removeprefix(MFP_FINGERPRINT_PREFIX))
    return fingerprints


def log_quantity(row: MfpFoodRow, mapping: Mapping[str, Any]) -> tuple[str, str]:
    if mapping.get("serving_mode") == "serving_unit":
        unit = str(mapping.get("serving_unit") or row.normalized_unit or "serving")
        return decimal_to_str(row.value), unit
    if row.normalized_unit not in {"g", "kg", "mg"}:
        serving_unit = str(mapping.get("serving_unit") or "")
        if serving_unit and row.normalized_unit == serving_unit:
            return decimal_to_str(row.value), serving_unit
    return decimal_to_str(row.value), row.normalized_unit or row.unit


def created_log_nutrients(log_row: Mapping[str, Any]) -> dict[str, Decimal]:
    output: dict[str, Decimal] = {}
    for nutrient in cast("Sequence[Mapping[str, Any]]", log_row.get("nutrients", [])):
        amount = decimal_or_none(str(nutrient.get("amount", "")))
        code = str(nutrient.get("code", ""))
        if amount is not None and code:
            output[code] = amount
    return output


def mismatch_entries(
    source: MfpFoodRow, created: Mapping[str, Any]
) -> list[dict[str, str]]:
    created_nutrients = created_log_nutrients(created)
    entries: list[dict[str, str]] = []
    for code in [
        "ENERGY_KCAL",
        "PROTEIN_G",
        "CARBS_G",
        "FAT_G",
        *sorted(source.nutrients),
    ]:
        if code not in source.nutrients:
            continue
        expected = source.nutrients[code]
        actual = created_nutrients.get(code)
        if actual is None:
            continue
        tolerance = CALORIE_TOLERANCE if code == "ENERGY_KCAL" else MACRO_TOLERANCE
        diff = actual - expected
        if abs(diff) > tolerance:
            entries.append(
                {
                    "date": source.date,
                    "row_number": str(source.row_number),
                    "description": source.description,
                    "nutrient_code": code,
                    "mfp_amount": decimal_to_str(expected),
                    "calco_amount": decimal_to_str(actual),
                    "diff": decimal_to_str(diff),
                    "tolerance": decimal_to_str(tolerance),
                }
            )
    return entries


def import_history(args: argparse.Namespace) -> None:
    client = ApiClient(args.api_url, args.session_token)
    food_map = load_food_map(args.food_map)
    rows, item_types = load_mfp_food_rows(args.input)
    mismatches: list[dict[str, str]] = []
    skipped = 0
    imported = 0
    duplicate = 0
    fingerprints_by_date: dict[str, set[str]] = {}

    for row in rows:
        mapping = food_map.get(row.food_key)
        if mapping is None:
            skipped += 1
            continue

        fingerprint = row_fingerprint(row)
        if row.date not in fingerprints_by_date:
            fingerprints_by_date[row.date] = existing_fingerprints(client, row.date)
        if fingerprint in fingerprints_by_date[row.date]:
            duplicate += 1
            continue

        amount, unit = log_quantity(row, mapping)
        payload = {
            "logged_at": f"{row.date}T12:00:00Z",
            "meal_slot": None,
            "item": {"type": "product", "id": mapping["product_id"]},
            "quantity": {"amount": amount, "unit": unit},
            "notes": (
                f"{MFP_FINGERPRINT_PREFIX}{fingerprint} imported_from=myfitnesspal"
            ),
        }
        created = client.create_log(payload)
        fingerprints_by_date[row.date].add(fingerprint)
        imported += 1
        mismatches.extend(mismatch_entries(row, created))

    os.makedirs(os.path.dirname(args.mismatch_report) or ".", exist_ok=True)
    with open(args.mismatch_report, "w", newline="", encoding="utf-8") as out_file:
        fieldnames = [
            "date",
            "row_number",
            "description",
            "nutrient_code",
            "mfp_amount",
            "calco_amount",
            "diff",
            "tolerance",
        ]
        writer = csv.DictWriter(out_file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(mismatches)

    log.info(
        "History import complete: imported=%d duplicates=%d "
        "skipped_no_mapping=%d mismatches=%d",
        imported,
        duplicate,
        skipped,
        len(mismatches),
    )
    log.info("Input item types: %s", dict(item_types))
    log.info("Wrote mismatch report to %s", args.mismatch_report)


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--input", default=DEFAULT_INPUT, help="MFP data-access CSV")
    parser.add_argument("--api-url", default=DEFAULT_API_URL, help="CalCo API base URL")
    parser.add_argument(
        "--session-token", default="", help="calco_session cookie value"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Import MyFitnessPal data into CalCo")
    subparsers = parser.add_subparsers(dest="command", required=True)

    dry_run = subparsers.add_parser("food-dry-run", help="Generate food review CSV")
    add_common_args(dry_run)
    dry_run.add_argument(
        "--output", default=DEFAULT_REVIEW, help="Review CSV output path"
    )
    dry_run.set_defaults(func=write_food_review)

    commit = subparsers.add_parser("food-commit", help="Import approved foods")
    add_common_args(commit)
    commit.add_argument(
        "--review", default=DEFAULT_REVIEW, help="Edited review CSV path"
    )
    commit.add_argument(
        "--output", default=DEFAULT_MAP, help="Resolved food map output path"
    )
    commit.set_defaults(func=write_food_map)

    history = subparsers.add_parser("history-import", help="Import MFP food history")
    add_common_args(history)
    history.add_argument(
        "--food-map", default=DEFAULT_MAP, help="Resolved food map JSON"
    )
    history.add_argument(
        "--mismatch-report",
        default=DEFAULT_MISMATCH_REPORT,
        help="Nutrient mismatch report CSV",
    )
    history.set_defaults(func=import_history)
    return parser


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)s  %(message)s",
        datefmt="%H:%M:%S",
    )
    parser = build_parser()
    args = parser.parse_args()
    if not os.path.exists(args.input):
        print(f"Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)
    if args.command in {"food-commit", "history-import"} and not args.session_token:
        print("--session-token is required for commit/import commands", file=sys.stderr)
        sys.exit(1)
    args.func(args)


if __name__ == "__main__":
    main()
