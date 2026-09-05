#!/usr/bin/env python3
"""Create foods from foods_to_create.jsonl via the running CalCo API."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT / "src"))

from mfp_nutrients import REQUIRED_MACRO_CODES

DATA_DIR = ROOT / "data"
DEFAULT_INPUT = DATA_DIR / "foods_to_create.jsonl"
DEFAULT_REVIEW_CSV = DATA_DIR / "step-10-out-food-match-review-merged.csv"
DEFAULT_API_URL = "http://localhost:3000"
DEFAULT_COOKIE_NAME = os.environ.get("SESSION_COOKIE_NAME", "calco_session")

DEFAULT_ADMIN_USERNAME = "admin"
DEFAULT_ADMIN_PASSWORD = "adminpassword"
DEFAULT_USER_USERNAME = "tester"
DEFAULT_USER_PASSWORD = "testpassword"

IMPORT_SOURCE = "USER"
IMPORT_SOURCE_PREFIX = "mfp-personal-data"
REVIEW_FINAL_COLUMNS = (
    "created_food_id",
    "created_food_name",
    "final_food_id",
    "final_food_name",
    "final_action",
    "ready_for_log_import",
)


class ApiError(RuntimeError):
    """Raised when the API returns an unexpected response."""


@dataclass
class CreatedFood:
    description: str
    product_id: str
    product_name: str
    visibility: str
    mode: str
    source_id: str | None = None


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def _normalize_description(value: str) -> str:
    return " ".join(value.replace("\xa0", " ").split()).strip()


def _stable_source_id(description: str) -> str:
    normalized = _normalize_description(description).casefold()
    digest = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]
    return f"{IMPORT_SOURCE_PREFIX}:{digest}"


def _cookie_string(name: str, token: str) -> str:
    return f"{name}={token}"


def _extract_error(response: requests.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        text = response.text.strip()
        return text or f"HTTP {response.status_code}"

    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            code = error.get("code", "error")
            message = error.get("message", "")
            return f"{code}: {message}".strip(": ")
    return json.dumps(payload)


def _check_ok(response: requests.Response, expected: int | tuple[int, ...]) -> None:
    allowed = (expected,) if isinstance(expected, int) else expected
    if response.status_code not in allowed:
        raise ApiError(
            f"{response.request.method} {response.request.url} failed with "
            f"{response.status_code}: {_extract_error(response)}"
        )


def _session_with_cookie(api_url: str, token: str) -> requests.Session:
    session = requests.Session()
    session.headers["Accept"] = "application/json"
    session.cookies.set(DEFAULT_COOKIE_NAME, token)
    session.headers["X-CalCo-API-URL"] = api_url
    return session


def _bootstrap_status(api_url: str) -> bool:
    response = requests.get(
        f"{api_url}/api/auth/bootstrap/status",
        timeout=30,
        headers={"Accept": "application/json"},
    )
    _check_ok(response, 200)
    payload = response.json()
    return bool(payload["admin_exists"])


def _login(api_url: str, username: str, password: str) -> requests.Session:
    session = requests.Session()
    session.headers["Accept"] = "application/json"
    response = session.post(
        f"{api_url}/api/auth/login",
        json={"username": username, "password": password},
        timeout=30,
    )
    _check_ok(response, 200)
    return session


def _bootstrap_admin(api_url: str, username: str, password: str) -> requests.Session:
    session = requests.Session()
    session.headers["Accept"] = "application/json"
    response = session.post(
        f"{api_url}/api/auth/bootstrap/admin",
        json={"username": username, "password": password},
        timeout=30,
    )
    _check_ok(response, 201)
    return session


def _login_or_bootstrap_admin(
    api_url: str,
    username: str | None,
    password: str | None,
) -> requests.Session | None:
    if username and password:
        try:
            return _login(api_url, username, password)
        except ApiError:
            if not _bootstrap_status(api_url):
                return _bootstrap_admin(api_url, username, password)
            raise

    if not _bootstrap_status(api_url):
        return _bootstrap_admin(api_url, DEFAULT_ADMIN_USERNAME, DEFAULT_ADMIN_PASSWORD)

    try:
        return _login(api_url, DEFAULT_ADMIN_USERNAME, DEFAULT_ADMIN_PASSWORD)
    except ApiError:
        return None


def _login_user(
    api_url: str,
    username: str | None,
    password: str | None,
) -> requests.Session | None:
    if username and password:
        return _login(api_url, username, password)

    try:
        return _login(api_url, DEFAULT_USER_USERNAME, DEFAULT_USER_PASSWORD)
    except ApiError:
        return None


def _create_temp_user(api_url: str, admin_session: requests.Session) -> tuple[str, str]:
    suffix = int(time.time())
    username = f"mfp-import-{suffix}"
    password = uuid.uuid4().hex
    payload = {
        "username": username,
        "display_name": username,
        "initial_password": password,
    }
    response = admin_session.post(
        f"{api_url}/api/admin/users",
        json=payload,
        timeout=30,
    )
    _check_ok(response, 201)
    return username, password


def _ensure_user_session(
    api_url: str,
    user_session: requests.Session | None,
    admin_session: requests.Session | None,
    username: str | None,
    password: str | None,
) -> requests.Session | None:
    if user_session is not None:
        return user_session

    direct = _login_user(api_url, username, password)
    if direct is not None:
        return direct

    if admin_session is None:
        return None

    temp_username, temp_password = _create_temp_user(api_url, admin_session)
    return _login(api_url, temp_username, temp_password)


def _stage_import_rows(records: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, str]]:
    foods: list[dict[str, Any]] = []
    nutrients: list[dict[str, Any]] = []
    servings: list[dict[str, Any]] = []
    source_ids_by_description: dict[str, str] = {}

    for row_number, record in enumerate(records, start=1):
        description = _normalize_description(str(record["name"]))
        source_id = _stable_source_id(description)
        source_ids_by_description[description] = source_id

        foods.append(
            {
                "row_number": row_number,
                "source": IMPORT_SOURCE,
                "source_id": source_id,
                "barcode": None,
                "name": description,
                "brand": record.get("brand"),
                "categories": record.get("categories") or [],
            }
        )

        for nutrient in record.get("nutrients", []):
            nutrients.append(
                {
                    "row_number": row_number,
                    "source": IMPORT_SOURCE,
                    "source_id": source_id,
                    "nutrient_code": nutrient["code"],
                    "amount_per_100g": nutrient["amount_per_100g"],
                }
            )

        for serving in record.get("servings", []):
            servings.append(
                {
                    "row_number": row_number,
                    "source": IMPORT_SOURCE,
                    "source_id": source_id,
                    "label": serving["label"],
                    "quantity": serving["quantity"],
                    "unit": serving["unit"],
                    "grams": serving["grams"],
                }
            )

    return foods, nutrients, servings, source_ids_by_description


def _custom_payload(record: dict[str, Any]) -> dict[str, Any]:
    payload = {
        key: value
        for key, value in record.items()
        if key in {
            "name",
            "brand",
            "categories",
            "default_quantity",
            "default_unit",
            "nutrients",
            "servings",
        }
    }
    seen_codes = {nutrient["code"] for nutrient in payload.get("nutrients", [])}
    nutrients = list(payload.get("nutrients", []))
    for code in REQUIRED_MACRO_CODES:
        if code not in seen_codes:
            nutrients.append(
                {
                    "code": code,
                    "amount_per_100g": 0,
                    "source": "mfp",
                    "confidence": "reviewed",
                }
            )
    payload["nutrients"] = nutrients
    return payload


def _create_import_job(api_url: str, admin_session: requests.Session) -> str:
    response = admin_session.post(
        f"{api_url}/api/imports",
        json={"source": IMPORT_SOURCE},
        timeout=30,
    )
    _check_ok(response, 201)
    return str(response.json()["id"])


def _stage_rows(
    api_url: str,
    admin_session: requests.Session,
    import_id: str,
    path: str,
    rows: list[dict[str, Any]],
) -> None:
    if not rows:
        return
    response = admin_session.post(
        f"{api_url}/api/imports/{import_id}/{path}",
        json={"rows": rows},
        timeout=60,
    )
    _check_ok(response, 200)


def _commit_import(api_url: str, admin_session: requests.Session, import_id: str) -> dict[str, Any]:
    response = admin_session.post(
        f"{api_url}/api/imports/{import_id}/commit",
        timeout=120,
    )
    _check_ok(response, 200)
    return response.json()


def _resolve_imported_products(
    api_url: str,
    user_session: requests.Session,
    source_ids_by_description: dict[str, str],
) -> dict[str, CreatedFood]:
    resolved: dict[str, CreatedFood] = {}
    for description, source_id in source_ids_by_description.items():
        response = user_session.get(
            f"{api_url}/api/foods/search",
            params={"q": description},
            timeout=30,
        )
        _check_ok(response, 200)
        items = response.json()["items"]
        matches = [
            item
            for item in items
            if item.get("source") == IMPORT_SOURCE and item.get("source_id") == source_id
        ]
        if len(matches) != 1:
            raise ApiError(
                f"Could not uniquely resolve imported product for {description!r}; "
                f"expected 1 match, got {len(matches)}"
            )
        match = matches[0]
        resolved[description] = CreatedFood(
            description=description,
            product_id=str(match["id"]),
            product_name=str(match["name"]),
            visibility="global",
            mode="import",
            source_id=source_id,
        )
    return resolved


def _create_global_foods(
    api_url: str,
    admin_session: requests.Session,
    user_session: requests.Session,
    records: list[dict[str, Any]],
) -> tuple[dict[str, CreatedFood], dict[str, Any]]:
    foods, nutrients, servings, source_ids_by_description = _stage_import_rows(records)
    import_id = _create_import_job(api_url, admin_session)
    _stage_rows(api_url, admin_session, import_id, "foods", foods)
    _stage_rows(api_url, admin_session, import_id, "nutrients", nutrients)
    _stage_rows(api_url, admin_session, import_id, "servings", servings)
    commit_result = _commit_import(api_url, admin_session, import_id)
    resolved = _resolve_imported_products(api_url, user_session, source_ids_by_description)
    return resolved, {"import_id": import_id, "commit": commit_result}


def _create_private_foods(
    api_url: str,
    user_session: requests.Session,
    records: list[dict[str, Any]],
) -> dict[str, CreatedFood]:
    created: dict[str, CreatedFood] = {}
    for record in records:
        payload = _custom_payload(record)
        response = user_session.post(
            f"{api_url}/api/foods/custom",
            json=payload,
            timeout=60,
        )
        _check_ok(response, 201)
        product_id = str(response.json()["id"])
        description = _normalize_description(str(record["name"]))
        created[description] = CreatedFood(
            description=description,
            product_id=product_id,
            product_name=description,
            visibility="user_private",
            mode="custom",
        )
    return created


def _ensure_review_columns(fieldnames: list[str]) -> list[str]:
    output = list(fieldnames)
    for column in REVIEW_FINAL_COLUMNS:
        if column not in output:
            output.append(column)
    return output


def _update_review_csv(
    review_csv: Path,
    created_by_description: dict[str, CreatedFood],
) -> dict[str, int]:
    with review_csv.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        fieldnames = _ensure_review_columns(reader.fieldnames or [])

    updated = 0
    finalized_matches = 0
    for row in rows:
        description = _normalize_description(row["description"])
        matched_food_id = row.get("matched_food_id", "").strip()
        if matched_food_id:
            row["final_food_id"] = matched_food_id
            row["final_food_name"] = row.get("matched_food_name", "").strip()
            row["final_action"] = "matched_existing"
            row["ready_for_log_import"] = "true"
            finalized_matches += 1
            continue

        created = created_by_description.get(description)
        if created is None:
            continue
        row["created_food_id"] = created.product_id
        row["created_food_name"] = created.product_name
        row["final_food_id"] = created.product_id
        row["final_food_name"] = created.product_name
        row["final_action"] = "created_new"
        row["ready_for_log_import"] = "true"
        updated += 1

    with review_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return {"created_rows_updated": updated, "matched_rows_finalized": finalized_matches}


def _load_auth_sessions(
    api_url: str,
    args: argparse.Namespace,
    visibility: str,
) -> tuple[requests.Session | None, requests.Session | None]:
    admin_session: requests.Session | None = None
    user_session: requests.Session | None = None

    if args.session_token:
        user_session = _session_with_cookie(api_url, args.session_token)

    if visibility != "private":
        if args.admin_session_token:
            admin_session = _session_with_cookie(api_url, args.admin_session_token)
        else:
            admin_session = _login_or_bootstrap_admin(
                api_url,
                args.admin_username,
                args.admin_password,
            )

    user_session = _ensure_user_session(
        api_url,
        user_session,
        admin_session if visibility != "private" else None,
        args.username,
        args.password,
    )
    return admin_session, user_session


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create MFP unmatched foods via the running CalCo API"
    )
    parser.add_argument("--api-url", default=os.environ.get("CALCO_API_URL", DEFAULT_API_URL))
    parser.add_argument("--input", default=str(DEFAULT_INPUT))
    parser.add_argument("--review-csv", default=str(DEFAULT_REVIEW_CSV))
    parser.add_argument(
        "--visibility",
        choices=("auto", "global", "private"),
        default="auto",
        help="Prefer global import, private custom foods, or auto-fallback",
    )
    parser.add_argument(
        "--session-token",
        default=os.environ.get("CALCO_SESSION_TOKEN"),
        help=f"{DEFAULT_COOKIE_NAME} cookie token for a regular user session",
    )
    parser.add_argument(
        "--admin-session-token",
        default=os.environ.get("CALCO_ADMIN_SESSION_TOKEN"),
        help=f"{DEFAULT_COOKIE_NAME} cookie token for an admin session",
    )
    parser.add_argument("--username", default=os.environ.get("CALCO_USERNAME"))
    parser.add_argument("--password", default=os.environ.get("CALCO_PASSWORD"))
    parser.add_argument("--admin-username", default=os.environ.get("CALCO_ADMIN_USERNAME"))
    parser.add_argument("--admin-password", default=os.environ.get("CALCO_ADMIN_PASSWORD"))
    args = parser.parse_args()

    api_url = args.api_url.rstrip("/")
    input_path = Path(args.input)
    review_csv = Path(args.review_csv)
    records = _load_jsonl(input_path)

    if not records:
        print(f"No records in {input_path}")
        return

    admin_session, user_session = _load_auth_sessions(api_url, args, args.visibility)

    created_by_description: dict[str, CreatedFood]
    result_meta: dict[str, Any] = {}

    if args.visibility in {"auto", "global"} and admin_session is not None:
        if user_session is None:
            raise ApiError(
                "Admin auth was available, but no user session could be established to resolve "
                "created global product IDs from the catalog API."
            )
        created_by_description, result_meta = _create_global_foods(
            api_url,
            admin_session,
            user_session,
            records,
        )
    elif args.visibility == "global":
        raise ApiError(
            "Global creation requested, but no admin session could be established."
        )
    else:
        if user_session is None:
            raise ApiError(
                "No user session could be established for custom-food creation."
            )
        created_by_description = _create_private_foods(api_url, user_session, records)

    review_result = _update_review_csv(review_csv, created_by_description)
    created_count = len(created_by_description)
    mode = next(iter(created_by_description.values())).mode if created_by_description else "none"
    visibility = (
        next(iter(created_by_description.values())).visibility
        if created_by_description
        else "unknown"
    )

    print(f"Created or resolved {created_count} foods via {mode} mode")
    print(f"  visibility:            {visibility}")
    print(f"  review rows updated:   {review_result['created_rows_updated']}")
    print(f"  matched rows finalized:{review_result['matched_rows_finalized']}")
    if "import_id" in result_meta:
        print(f"  import_id:             {result_meta['import_id']}")
        print(f"  commit:                {json.dumps(result_meta['commit'], sort_keys=True)}")


if __name__ == "__main__":
    try:
        main()
    except ApiError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
