"""Import historical MFP food rows into CalCo diary logs."""

from __future__ import annotations

import csv
import hashlib
import json
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from mfp_nutrients import MFP_NUTRIENT_MAPPINGS
from steps import load_csv, parse_serving

DEFAULT_API_URL = "http://127.0.0.1:3001"
DEFAULT_COOKIE_NAME = "calco_session"
DEFAULT_DEVICE_TIMEZONE = "Asia/Kolkata"
IMPORT_SOURCE = "myfitnesspal"
FINGERPRINT_PREFIX = "mfp_import_fingerprint="
NOTE_PREFIX = f"imported_from={IMPORT_SOURCE}"
MEAL_SLOT_MAP = {
    "Breakfast": "breakfast",
    "Lunch": "lunch",
    "Dinner": "dinner",
    "Snacks": "snack",
    "Supplements": "snack",
}


class ImportError(RuntimeError):
    """Raised when the import cannot proceed."""


@dataclass(frozen=True)
class ReviewRow:
    description: str
    final_food_id: str
    example_serving_amount: Decimal
    serving_grams: Decimal
    ready_for_log_import: bool


def _clean_text(value: str) -> str:
    return " ".join(value.replace("\xa0", " ").split()).strip()


def _normalize_description(value: str) -> str:
    return _clean_text(value).casefold()


def _parse_decimal(value: str, *, field: str) -> Decimal:
    text = value.strip()
    if not text:
        msg = f"Missing decimal value for {field}"
        raise ImportError(msg)
    try:
        return Decimal(text)
    except InvalidOperation as exc:
        msg = f"Invalid decimal value for {field}: {value!r}"
        raise ImportError(msg) from exc


def _parse_optional_positive_decimal(value: str) -> Decimal | None:
    text = value.strip()
    if not text:
        return None
    try:
        parsed = Decimal(text)
    except InvalidOperation as exc:
        msg = f"Invalid decimal value: {value!r}"
        raise ImportError(msg) from exc
    if parsed <= 0:
        return None
    return parsed


def _serving_grams(row: dict[str, str]) -> Decimal:
    for column in ("corrected_serving_grams", "current_serving_grams"):
        parsed = _parse_optional_positive_decimal(row.get(column, ""))
        if parsed is not None:
            return parsed
    msg = f"Missing serving grams for {row['description']!r}"
    raise ImportError(msg)


def _example_serving_amount(row: dict[str, str]) -> Decimal:
    amount_text, _unit = parse_serving(row.get("example_serving", ""))
    if amount_text:
        return _parse_decimal(
            amount_text,
            field=f"example_serving for {row['description']}",
        )

    example_value = _parse_optional_positive_decimal(row.get("example_value", ""))
    if example_value is not None:
        return example_value

    if row.get("reference_basis", "").strip() == "per_serving":
        return Decimal(1)

    msg = f"Missing example serving for {row['description']!r}"
    raise ImportError(msg)


def load_review_rows(path: str | Path) -> dict[str, ReviewRow]:
    with Path(path).open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    review_rows: dict[str, ReviewRow] = {}
    for row in rows:
        description = _clean_text(row["description"])
        normalized = _normalize_description(description)
        final_food_id = row.get("final_food_id", "").strip()
        if not final_food_id:
            msg = f"Missing final_food_id for {description!r}"
            raise ImportError(msg)
        review_rows[normalized] = ReviewRow(
            description=description,
            final_food_id=final_food_id,
            example_serving_amount=_example_serving_amount(row),
            serving_grams=_serving_grams(row),
            ready_for_log_import=(
                row.get("ready_for_log_import", "").strip().lower() == "true"
            ),
        )
    return review_rows


def normalize_meal_slot(value: str) -> str:
    meal_slot = MEAL_SLOT_MAP.get(_clean_text(value))
    if meal_slot is None:
        msg = f"Unsupported meal slot: {value!r}"
        raise ImportError(msg)
    return meal_slot


def grams_for_food_row(food_row: dict[str, str], review_row: ReviewRow) -> Decimal:
    unit = _clean_text(food_row.get("unit", "")).casefold()
    value = _parse_decimal(
        food_row["value"],
        field=f"value for {food_row['description']}",
    )

    if unit == "g":
        return value

    if review_row.example_serving_amount <= 0:
        msg = f"Non-positive example serving amount for {review_row.description!r}"
        raise ImportError(
            msg
        )

    return (value * review_row.serving_grams) / review_row.example_serving_amount


def fingerprint_for_food_row(food_row: dict[str, str]) -> str:
    payload = {
        "date": _clean_text(food_row.get("date", "")),
        "meal": _clean_text(food_row.get("meal", "")),
        "description": _clean_text(food_row.get("description", "")),
        "value": _clean_text(food_row.get("value", "")),
        "unit": _clean_text(food_row.get("unit", "")),
        "serving": _clean_text(food_row.get("serving", "")),
    }
    for mapping in MFP_NUTRIENT_MAPPINGS:
        payload[mapping.source_column] = _clean_text(
            food_row.get(mapping.source_column, "")
        )
    return hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def import_note(fingerprint: str) -> str:
    return f"{NOTE_PREFIX} {FINGERPRINT_PREFIX}{fingerprint}"


def extract_import_fingerprint(notes: str | None) -> str | None:
    if not notes:
        return None
    for token in notes.split():
        if token.startswith(FINGERPRINT_PREFIX):
            return token[len(FINGERPRINT_PREFIX) :]
    return None


def _json_number(value: Decimal) -> int | float:
    normalized = value.normalize()
    if normalized == normalized.to_integral():
        return int(normalized)
    return float(round(value, 4))


def build_log_payload(
    food_row: dict[str, str],
    review_row: ReviewRow,
    *,
    device_timezone: str,
    grams: Decimal | None = None,
) -> dict[str, Any]:
    grams = grams if grams is not None else grams_for_food_row(food_row, review_row)
    fingerprint = fingerprint_for_food_row(food_row)
    return {
        "log_date": _clean_text(food_row["date"]),
        "meal_slot": normalize_meal_slot(food_row["meal"]),
        "device_timezone": device_timezone,
        "item": {
            "type": "product",
            "id": review_row.final_food_id,
        },
        "quantity": {
            "amount": _json_number(grams),
            "unit": "g",
        },
        "notes": import_note(fingerprint),
    }


def _request_json(
    method: str,
    url: str,
    *,
    cookie_name: str,
    session_token: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    headers = {
        "Accept": "application/json",
        "Cookie": f"{cookie_name}={session_token}",
    }
    data: bytes | None = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")

    request = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else None
    except HTTPError as exc:
        message = exc.read().decode("utf-8", errors="replace")
        msg = f"{method} {url} failed with {exc.code}: {message}"
        raise ImportError(msg) from exc
    except URLError as exc:
        msg = f"{method} {url} failed: {exc}"
        raise ImportError(msg) from exc


def _list_logs_by_date(
    api_url: str,
    log_date: str,
    *,
    cookie_name: str,
    session_token: str,
) -> list[dict[str, Any]]:
    query = urlencode({"log_date": log_date})
    payload = _request_json(
        "GET",
        f"{api_url}/api/logs?{query}",
        cookie_name=cookie_name,
        session_token=session_token,
    )
    if payload is None:
        return []
    return list(payload.get("items", []))


def _imported_fingerprints(items: list[dict[str, Any]]) -> set[str]:
    fingerprints: set[str] = set()
    for item in items:
        fingerprint = extract_import_fingerprint(item.get("notes"))
        if fingerprint:
            fingerprints.add(fingerprint)
    return fingerprints


def run(
    history_csv: str | Path,
    review_csv: str | Path,
    *,
    api_url: str,
    session_token: str,
    cookie_name: str = DEFAULT_COOKIE_NAME,
    device_timezone: str = DEFAULT_DEVICE_TIMEZONE,
    dry_run: bool = False,
    limit: int | None = None,
) -> dict[str, int]:
    _fieldnames, rows = load_csv(history_csv)
    review_rows = load_review_rows(review_csv)

    food_rows = [
        row for row in rows if _clean_text(row.get("item_type", "")) == "Foods"
    ]

    imported = 0
    skipped_existing = 0
    skipped_non_ready = 0
    skipped_non_positive = 0
    processed = 0
    fingerprints_by_date: dict[str, set[str]] = {}

    for row in food_rows:
        description_key = _normalize_description(row["description"])
        review_row = review_rows.get(description_key)
        if review_row is None:
            msg = f"No final food mapping for {row['description']!r}"
            raise ImportError(msg)
        if not review_row.ready_for_log_import:
            skipped_non_ready += 1
            continue

        log_date = _clean_text(row["date"])
        if log_date not in fingerprints_by_date:
            existing_logs = _list_logs_by_date(
                api_url,
                log_date,
                cookie_name=cookie_name,
                session_token=session_token,
            )
            fingerprints_by_date[log_date] = _imported_fingerprints(existing_logs)

        fingerprint = fingerprint_for_food_row(row)
        if fingerprint in fingerprints_by_date[log_date]:
            skipped_existing += 1
            continue

        grams = grams_for_food_row(row, review_row)
        if grams <= 0:
            skipped_non_positive += 1
            continue

        payload = build_log_payload(
            row,
            review_row,
            device_timezone=device_timezone,
            grams=grams,
        )

        if not dry_run:
            _request_json(
                "POST",
                f"{api_url}/api/logs",
                cookie_name=cookie_name,
                session_token=session_token,
                payload=payload,
            )
            fingerprints_by_date[log_date].add(fingerprint)

        imported += 1
        processed += 1
        if limit is not None and processed >= limit:
            break

    return {
        "imported": imported,
        "skipped_existing": skipped_existing,
        "skipped_non_ready": skipped_non_ready,
        "skipped_non_positive": skipped_non_positive,
        "food_rows": len(food_rows),
    }
