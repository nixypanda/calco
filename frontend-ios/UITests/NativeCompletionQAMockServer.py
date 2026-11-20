#!/usr/bin/env python3
"""Deterministic loopback API used only by NativeCompletionUITests.

This is a QA fixture, not a CalCo server. It has no external dependencies,
listens only on 127.0.0.1, accepts only the fake fixture credentials
``native-qa`` / ``native-qa``, and keeps every record in memory. Starting a
new process (or POSTing /__qa/reset) discards all state.

The UI test bundle skips these tests unless GET /__qa/health identifies this
exact fixture. Nothing here is used by the app's Debug/Release configuration.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FIXTURE_USERNAME = "native-qa"
FIXTURE_PASSWORD = "native-qa"
COOKIE_NAME = "calco_session"
ACCOUNT_HEADER = "X-CalCo-Account-ID"
FIXTURE_PROFILE_ID = "22222222-2222-4222-8222-222222222222"

NUTRIENTS = [
    {"code": "ENERGY_KCAL", "amount": "100", "unit": "kcal"},
    {"code": "PROTEIN_G", "amount": "1", "unit": "g"},
    {"code": "CARBS_G", "amount": "20", "unit": "g"},
    {"code": "FAT_G", "amount": "0.5", "unit": "g"},
    {"code": "FIBER_G", "amount": "2", "unit": "g"},
]

# Client-required custom-food nutrients. The production validation requires
# all four; a partial catalog must not make a required row look optional.
REQUIRED_NUTRIENT_CATALOG = [
    {"code": "ENERGY_KCAL", "name": "Energy", "unit": "kcal", "category": "energy"},
    {"code": "PROTEIN_G", "name": "Protein", "unit": "g", "category": "macro"},
    {"code": "CARBS_G", "name": "Carbohydrates", "unit": "g", "category": "macro"},
    {"code": "FAT_G", "name": "Fat", "unit": "g", "category": "macro"},
]
NUTRIENT_CATALOG = REQUIRED_NUTRIENT_CATALOG + [
    {"code": "FIBER_G", "name": "Fiber", "unit": "g", "category": "macro"},
]
CATALOG_UNITS = {row["code"]: row["unit"] for row in NUTRIENT_CATALOG}


def today_from_reset(body: dict) -> dt.date:
    raw = body.get("today")
    if isinstance(raw, str):
        try:
            return dt.date.fromisoformat(raw)
        except ValueError:
            pass
    return dt.date.today()


def iso_date(value: dt.date) -> str:
    return value.isoformat()


def nutrient_amounts(amount: float) -> list[dict]:
    factor = amount / 100.0
    return [
        {"code": "ENERGY_KCAL", "amount": f"{100.0 * factor:g}", "unit": "kcal"},
        {"code": "PROTEIN_G", "amount": f"{1.0 * factor:g}", "unit": "g"},
        {"code": "CARBS_G", "amount": f"{20.0 * factor:g}", "unit": "g"},
        {"code": "FAT_G", "amount": f"{0.5 * factor:g}", "unit": "g"},
        {"code": "FIBER_G", "amount": f"{2.0 * factor:g}", "unit": "g"},
    ]


def make_product(
    product_id: str,
    name: str,
    brand: str | None = "Native QA",
    nutrients: list[dict] | None = None,
) -> dict:
    nutrient_rows = nutrients or [
        {"code": "ENERGY_KCAL", "amount_per_100g": "100", "unit": "kcal"},
        {"code": "PROTEIN_G", "amount_per_100g": "1", "unit": "g"},
        {"code": "CARBS_G", "amount_per_100g": "20", "unit": "g"},
        {"code": "FAT_G", "amount_per_100g": "0.5", "unit": "g"},
    ]
    summary = {
        "energy_kcal": "100",
        "protein_g": "1",
        "carbs_g": "20",
        "fat_g": "0.5",
        "fiber_g": "2",
    }
    return {
        "id": product_id,
        "source": "custom",
        "source_id": product_id,
        "visibility": "private",
        "barcode": None,
        "name": name,
        "brand": brand,
        "categories": ["Fixture"],
        "default_quantity": "100",
        "default_unit": "g",
        "nutrition_summary": {"per_100g": summary},
        "nutrients": nutrient_rows,
        "servings": [],
        "allowed_units": [
            {"code": "g", "name": "Gram", "kind": "mass"},
            {"code": "serving", "name": "Serving", "kind": "serving"},
        ],
    }


def make_custom_product(product_id: str, body: dict) -> dict:
    nutrient_rows: list[dict] = []
    for item in body.get("nutrients") or []:
        code = str(item.get("code") or "")
        if not code:
            continue
        nutrient_rows.append(
            {
                "code": code,
                "amount_per_100g": str(item.get("amount_per_100g") or "0"),
                "unit": CATALOG_UNITS.get(code, ""),
            }
        )
    product = make_product(
        product_id,
        str(body.get("name") or "Native QA custom food"),
        brand=body.get("brand"),
        nutrients=nutrient_rows or None,
    )
    categories = body.get("categories")
    if isinstance(categories, list):
        product["categories"] = [str(category) for category in categories]
    if body.get("default_quantity") is not None:
        product["default_quantity"] = str(body["default_quantity"])
    if body.get("default_unit") is not None:
        product["default_unit"] = str(body["default_unit"])
    servings = body.get("servings")
    if isinstance(servings, list):
        product["servings"] = [
            {
                "unit": str(item.get("unit") or ""),
                "grams_per_unit": str(item.get("grams_per_unit") or "0"),
            }
            for item in servings
        ]
    for item in product.get("nutrients") or []:
        item.setdefault("source", "fixture")
        item.setdefault("confidence", "high")
    return product


PRODUCT_BASES = {
    "qa-apple": {"name": "Native QA Apple", "energy": 100.0, "protein": 1.0, "carbs": 20.0, "fat": 0.5},
    "qa-pear": {"name": "Native QA Pear", "energy": 80.0, "protein": 0.5, "carbs": 18.0, "fat": 0.2},
}


def product_name(state: "FixtureState", product_id: str) -> str | None:
    if product_id in state.removed_food_ids:
        return None
    base = PRODUCT_BASES.get(product_id)
    if base is not None:
        return base["name"]
    for food in state.custom_foods:
        if food["id"] == product_id:
            return food["name"]
    return None


def product_nutrition(state: "FixtureState", product_id: str) -> dict:
    base = PRODUCT_BASES.get(product_id)
    if base is not None:
        return base
    for food in state.custom_foods:
        if food["id"] == product_id:
            summary = food.get("nutrition_summary", {}).get("per_100g", {})
            return {
                "name": food["name"],
                "energy": float(summary.get("energy_kcal", "0")),
                "protein": float(summary.get("protein_g", "0")),
                "carbs": float(summary.get("carbs_g", "0")),
                "fat": float(summary.get("fat_g", "0")),
            }
    return {"name": "", "energy": 0.0, "protein": 0.0, "carbs": 0.0, "fat": 0.0}


def make_meal(
    state: "FixtureState",
    meal_id: str,
    body: dict,
    existing: dict | None = None,
) -> dict:
    components: list[dict] = []
    energy = protein = carbs = fat = 0.0
    total_grams = 0.0
    for index, item in enumerate(body.get("components") or []):
        reference = item.get("item") or {}
        product_id = str(reference.get("id") or "")
        quantity = item.get("quantity") or {}
        amount = str(quantity.get("amount") or "100")
        unit = str(quantity.get("unit") or "g")
        grams = float(amount) if unit == "g" else 0.0
        total_grams += grams
        base = product_nutrition(state, product_id)
        factor = grams / 100.0
        energy += base["energy"] * factor
        protein += base["protein"] * factor
        carbs += base["carbs"] * factor
        fat += base["fat"] * factor
        components.append(
            {
                "id": f"{meal_id}-component-{index + 1}",
                "item": {"type": "product", "id": product_id},
                "quantity": {"amount": amount, "unit": unit},
                "nutrition_summary": {
                    "energy_kcal": f"{base['energy'] * factor:g}",
                    "protein_g": f"{base['protein'] * factor:g}",
                    "carbs_g": f"{base['carbs'] * factor:g}",
                    "fat_g": f"{base['fat'] * factor:g}",
                },
            }
        )
    total_quantity = body.get("total_quantity")
    if not isinstance(total_quantity, dict) or not total_quantity:
        total_quantity = {
            "amount": f"{total_grams:g}" if total_grams > 0 else "100",
            "unit": "g",
        }
    timestamp = "2026-11-19T12:00:00Z"
    return {
        "id": meal_id,
        "name": str(body.get("name") or "Native QA Meal"),
        "notes": body.get("notes"),
        "total_quantity": {
            "amount": str(total_quantity.get("amount") or "100"),
            "unit": str(total_quantity.get("unit") or "g"),
        },
        "nutrition_summary": {
            "energy_kcal": f"{energy:g}",
            "protein_g": f"{protein:g}",
            "carbs_g": f"{carbs:g}",
            "fat_g": f"{fat:g}",
        },
        "components": components,
        "has_missing_components": False,
        "created_at": (existing or {}).get("created_at", timestamp),
        "updated_at": timestamp,
    }


def decorate_meal(state: "FixtureState", meal: dict) -> dict:
    decorated = copy.deepcopy(meal)
    missing = False
    for component in decorated.get("components") or []:
        product_id = str((component.get("item") or {}).get("id") or "")
        name = product_name(state, product_id)
        if name is None:
            component["missing"] = True
            component["missing_reason"] = "product_not_found"
            component["name"] = "Unavailable food"
            missing = True
        else:
            component.pop("missing", None)
            component.pop("missing_reason", None)
            component["name"] = name
    decorated["has_missing_components"] = missing
    return decorated


def make_log(
    log_id: str,
    log_date: str,
    meal_slot: str,
    name: str,
    amount: str = "100",
    unit: str = "g",
    notes: str | None = None,
) -> dict:
    return {
        "id": log_id,
        "log_date": log_date,
        "device_timezone": "Europe/London",
        "meal_slot": meal_slot,
        "item": {
            "type": "product",
            "id": "qa-apple",
            "name": name,
            "brand": "Native QA",
        },
        "quantity": {"amount": amount, "unit": unit},
        "nutrients": nutrient_amounts(float(amount)),
        "notes": notes,
    }


class FixtureState:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.reset({})

    def reset(self, body: dict) -> dict:
        with self.lock:
            today = today_from_reset(body)
            historical = today - dt.timedelta(days=1)
            self.today = iso_date(today)
            self.historical = iso_date(historical)
            self.identity_id = str(uuid.uuid4())
            self.profile_id = FIXTURE_PROFILE_ID
            # Backwards-compatible state alias: journal account scope remains
            # the identity UUID; the request binding header uses profile_id.
            self.account_id = self.identity_id
            self.session_token = "qa-session-" + uuid.uuid4().hex
            self.log_post_mode = body.get("log_post", "success")
            if self.log_post_mode not in {"success", "fail_once", "conflict"}:
                self.log_post_mode = "success"
            self.seed_logs = body.get("seed_logs", True) is not False
            self.recent_items = [
                {
                    "item": {
                        "type": "product",
                        "id": "qa-apple",
                        "name": "Native QA Apple",
                        "brand": "Native QA",
                    },
                    "last_used_date": self.historical,
                    "meal_slot": "breakfast",
                    "quantity": {"amount": "100", "unit": "g"},
                    "nutrition_summary": {
                        "energy_kcal": "100",
                        "protein_g": "1",
                        "carbs_g": "20",
                        "fat_g": "0.5",
                        "fiber_g": "2",
                    },
                    "top_quantities": [
                        {"quantity": {"amount": "100", "unit": "g"}, "log_count": 3},
                        {"quantity": {"amount": "50", "unit": "g"}, "log_count": 1},
                    ],
                },
                {
                    "item": {
                        "type": "product",
                        "id": "qa-pear",
                        "name": "Native QA Pear",
                        "brand": "Native QA",
                    },
                    "last_used_date": self.historical,
                    "meal_slot": "lunch",
                    "quantity": {"amount": "1", "unit": "serving"},
                    "nutrition_summary": {
                        "energy_kcal": "80",
                        "protein_g": "0.5",
                        "carbs_g": "18",
                        "fat_g": "0.2",
                        "fiber_g": "3",
                    },
                    "top_quantities": [
                        {"quantity": {"amount": "1", "unit": "serving"}, "log_count": 2}
                    ],
                },
            ]
            self.custom_foods: list[dict] = []
            self.custom_food_create_count = 0
            self.custom_food_update_count = 0
            self.custom_food_delete_count = 0
            self.removed_food_ids: set[str] = set()
            self.assistant_enabled = body.get("assistant_enabled") is True
            self.assistant_draft_request_count = 0
            self.assistant_last_purpose: str | None = None
            self.meal_create_count = 0
            self.meal_update_count = 0
            self.meal_delete_count = 0
            self.logs: list[dict] = []
            if self.seed_logs:
                self.logs = [
                    make_log(
                        "hist-log-001",
                        self.historical,
                        "breakfast",
                        "Historical Oats",
                        notes="Native QA historical breakfast",
                    ),
                    make_log("hist-log-002", self.historical, "breakfast", "Historical Yogurt"),
                    make_log("hist-log-003", self.historical, "lunch", "Historical Rice"),
                    make_log("hist-log-004", self.historical, "lunch", "Historical Beans"),
                    make_log("hist-log-005", self.historical, "dinner", "Historical Pasta"),
                    make_log("hist-log-006", self.historical, "dinner", "Historical Sauce"),
                    make_log("hist-log-007", self.historical, "snack", "Historical Apple"),
                    make_log(
                        "hist-log-008",
                        self.historical,
                        "late_night_snack",
                        "Historical Tea",
                        notes="Retained slot",
                    ),
                ]
            self.goal = {
                "requested_date": self.today,
                "effective_from": None,
                "source": "saved",
                "calorie_target": 2000,
                "protein_target_g": 150,
                "carbs_target_g": 250,
                "fat_target_g": 70,
            }
            self.enabled_slots = [
                "breakfast",
                "lunch",
                "dinner",
                "snack",
                "late_night_snack",
            ]
            self.failed_once_keys: set[str] = set()
            self.idempotency: dict[str, str] = {}
            self.batch_idempotency: dict[str, list[str]] = {}
            self.log_post_attempts = 0
            self.protected_request_count = 0
            self.bound_request_count = 0
            self.unbound_protected_request_count = 0
            self.api_keys: list[dict] = [
                {
                    "id": "qa-api-key-1",
                    "name": "Native QA existing key",
                    "token_hint": "qa_…0001",
                    "scope": "read",
                    "created_at": "2026-11-01T10:00:00Z",
                    "last_used_at": None,
                    "expires_at": None,
                }
            ]
            self.meals: list[dict] = [
                {
                    "id": "qa-meal-1",
                    "name": "Native QA Meal",
                    "notes": "Fixture meal",
                    "total_quantity": {"amount": "1", "unit": "serving"},
                    "nutrition_summary": {
                        "energy_kcal": "200",
                        "protein_g": "2",
                        "carbs_g": "40",
                        "fat_g": "1",
                        "fiber_g": "4",
                    },
                    "components": [
                        {
                            "id": "qa-meal-component-1",
                            "item": {"type": "product", "id": "qa-apple"},
                            "quantity": {"amount": "100", "unit": "g"},
                            "nutrition_summary": {
                                "energy_kcal": "100",
                                "protein_g": "1",
                                "carbs_g": "20",
                                "fat_g": "0.5",
                                "fiber_g": "2",
                            },
                        }
                    ],
                    "created_at": "2026-11-01T10:00:00Z",
                    "updated_at": "2026-11-01T10:00:00Z",
                }
            ]
            return self.summary()

    def summary(self) -> dict:
        return {
            "ok": True,
            "fixture": "native-completion-qa",
            "today": self.today,
            "historical": self.historical,
            "account_id": self.identity_id,
            "identity_id": self.identity_id,
            "profile_id": self.profile_id,
            "account_header": ACCOUNT_HEADER,
            "log_post": self.log_post_mode,
        }

    def session(self) -> dict:
        return {
            "identity": {
                "id": self.identity_id,
                "username": FIXTURE_USERNAME,
                "role": "user",
            },
            "profile": {
                "id": self.profile_id,
                "display_name": "Native QA User",
            },
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CalCoNativeQAMock/1.0"

    _request_body: bytes | None = None

    @property
    def state(self) -> FixtureState:
        return self.server.state  # type: ignore[attr-defined]

    def handle_one_request(self) -> None:
        # Keep-alive reuses this handler instance. A cached POST body from the
        # previous request would otherwise leave the next body unread.
        self._request_body = None
        super().handle_one_request()

    def log_message(self, fmt: str, *args) -> None:
        # Keep xcodebuild output readable; tests assert state, not logs.
        if getattr(self.server, "verbose", False):
            print("QA_MOCK " + (fmt % args), flush=True)

    # MARK: - plumbing

    def _body(self) -> bytes:
        if self._request_body is not None:
            return self._request_body
        transfer_encoding = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in transfer_encoding:
            chunks: list[bytes] = []
            while True:
                line = self.rfile.readline(65537).strip()
                size = int(line.split(b";", 1)[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline(65537)
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            self._request_body = b"".join(chunks)
        else:
            length = int(self.headers.get("Content-Length", "0") or "0")
            self._request_body = self.rfile.read(length) if length else b""
        return self._request_body

    def _json_body(self) -> dict:
        raw = self._body()
        if not raw:
            return {}
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def _send(self, status: int, payload: object | None = None, headers=None) -> None:
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or []):
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _error(self, status: int, code: str, message: str) -> None:
        self._send(status, {"error": {"code": code, "message": message}})

    def _authorized(self) -> bool:
        cookie_header = self.headers.get("Cookie", "")
        for part in cookie_header.split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE_NAME and value == self.state.session_token:
                return True
        return False

    def _require_auth(self) -> bool:
        if not self._authorized():
            self._error(401, "unauthorized", "Sign in required.")
            return False
        self.state.protected_request_count += 1
        raw = self.headers.get(ACCOUNT_HEADER)
        # Header absence is allowed for legacy/read-only checks. Native scoped
        # actions must send it; if present it is never ignored. Counters let the
        # acceptance suite prove the native client is bound, not just accepted.
        if raw is None:
            self.state.unbound_protected_request_count += 1
            return True
        candidate = raw.strip()
        try:
            parsed = uuid.UUID(candidate)
        except (ValueError, AttributeError):
            self._error(400, "invalid_account_header", "Malformed account binding header.")
            return False
        if str(parsed).lower() != self.state.profile_id.lower():
            self._error(
                401,
                "session_account_changed",
                "Authenticated account does not match the expected profile.",
            )
            return False
        self.state.bound_request_count += 1
        return True

    def _query(self) -> dict[str, list[str]]:
        return parse_qs(urlparse(self.path).query)

    def _multipart_conversation(self) -> dict | None:
        content_type = self.headers.get("Content-Type", "")
        if not content_type.lower().startswith("multipart/form-data"):
            return None
        boundary: str | None = None
        for part in content_type.split(";"):
            name, _, value = part.strip().partition("=")
            if name.lower() == "boundary":
                boundary = value.strip().strip('"')
        if not boundary:
            return None
        raw = self._body()
        for part in raw.split(("--" + boundary).encode("utf-8")):
            headers, _, data = part.partition(b"\r\n\r\n")
            if b'name="conversation"' not in headers:
                continue
            try:
                return json.loads(data.strip().decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return None
        return None

    # MARK: - routes

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/__qa/health":
            self._send(200, self.state.summary())
            return
        if path == "/__qa/state":
            with self.state.lock:
                self._send(
                    200,
                    {
                        "log_count": len(self.state.logs),
                        "log_ids": [log["id"] for log in self.state.logs],
                        "logs": [
                            {
                                "id": log["id"],
                                "date": log["log_date"],
                                "meal_slot": log.get("meal_slot"),
                                "amount": log["quantity"]["amount"],
                                "unit": log["quantity"]["unit"],
                            }
                            for log in self.state.logs
                        ],
                        "log_post_attempts": self.state.log_post_attempts,
                        "idempotency_keys": len(self.state.idempotency),
                        "api_key_count": len(self.state.api_keys),
                        "goal_calories": self.state.goal.get("calorie_target"),
                        "custom_food_count": len(self.state.custom_foods),
                        "custom_food_create_count": self.state.custom_food_create_count,
                        "custom_food_update_count": self.state.custom_food_update_count,
                        "custom_food_delete_count": self.state.custom_food_delete_count,
                        "assistant_enabled": self.state.assistant_enabled,
                        "assistant_draft_request_count": self.state.assistant_draft_request_count,
                        "assistant_last_purpose": self.state.assistant_last_purpose,
                        "meal_count": len(self.state.meals),
                        "meal_create_count": self.state.meal_create_count,
                        "meal_update_count": self.state.meal_update_count,
                        "meal_delete_count": self.state.meal_delete_count,
                        "protected_request_count": self.state.protected_request_count,
                        "bound_request_count": self.state.bound_request_count,
                        "unbound_protected_request_count": self.state.unbound_protected_request_count,
                    },
                )
            return
        if path == "/api/auth/bootstrap/status":
            self._send(200, {"admin_exists": True})
            return
        if path == "/api/auth/session":
            if not self._authorized():
                self._error(401, "not_found", "No session.")
                return
            self._send(200, self.state.session())
            return
        if not self._require_auth():
            return

        if path in {"/api/logs/recent-items", "/api/logs/last-used"}:
            with self.state.lock:
                self._send(200, {"items": copy.deepcopy(self.state.recent_items)})
            return
        if path == "/api/logs/latest-slots":
            with self.state.lock:
                breakfast = [
                    copy.deepcopy(log)
                    for log in self.state.logs
                    if log["log_date"] == self.state.historical
                    and log["meal_slot"] == "breakfast"
                ]
                self._send(
                    200,
                    {
                        "slots": [
                            {
                                "source_date": self.state.historical,
                                "meal_slot": "breakfast",
                                "items": breakfast,
                            }
                        ]
                    },
                )
            return
        if path == "/api/logs/summary":
            query = self._query()
            start = (query.get("from_date") or [self.state.today])[0]
            end = (query.get("to_date") or [self.state.today])[0]
            days = []
            with self.state.lock:
                for log in self.state.logs:
                    if start <= log["log_date"] <= end:
                        days.append(log["log_date"])
            unique = sorted(set(days))
            self._send(
                200,
                {
                    "days": [
                        {
                            "date": day,
                            "energy_kcal": "800",
                            "protein_g": "8",
                            "carbs_g": "160",
                            "fat_g": "4",
                        }
                        for day in unique
                    ]
                },
            )
            return
        if path == "/api/logs":
            requested = (self._query().get("log_date") or [""])[0]
            with self.state.lock:
                items = [
                    copy.deepcopy(log)
                    for log in self.state.logs
                    if log["log_date"] == requested
                ]
            self._send(200, {"log_date": requested, "items": items})
            return
        if path.startswith("/api/logs/"):
            log_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                log = next(
                    (item for item in self.state.logs if item["id"] == log_id),
                    None,
                )
            if log is None:
                self._error(404, "not_found", "Log not found.")
            else:
                self._send(200, log)
            return
        if path == "/api/goal":
            date = (self._query().get("date") or [self.state.today])[0]
            with self.state.lock:
                payload = copy.deepcopy(self.state.goal)
            payload["requested_date"] = date
            self._send(200, payload)
            return
        if path == "/api/diary-preferences":
            with self.state.lock:
                self._send(200, {"enabled_meal_slots": list(self.state.enabled_slots)})
            return
        if path == "/api/ai/food-assistant/status":
            self._send(
                200,
                {
                    "enabled": self.state.assistant_enabled,
                    "supports_images": False,
                },
            )
            return
        if path == "/api/capabilities":
            self._send(
                200,
                {
                    "log_creation_idempotency": {
                        "version": 2,
                        "single": True,
                        "ad_hoc": True,
                        "batch": True,
                        "batch_key_location": "top_level",
                        "deleted_operation_replay": "conflict",
                        "pre_migration_deleted_keys": "reconciliation_only",
                        "request_account_binding": "x-calco-account-id",
                    }
                },
            )
            return
        if path == "/api/units":
            self._send(
                200,
                {
                    "items": [
                        {"code": "g", "name": "Gram", "kind": "mass"},
                        {"code": "ml", "name": "Millilitre", "kind": "volume"},
                    ]
                },
            )
            return
        if path == "/api/foods/custom":
            with self.state.lock:
                self._send(200, {"items": copy.deepcopy(self.state.custom_foods)})
            return
        if path == "/api/nutrients":
            self._send(200, {"items": copy.deepcopy(NUTRIENT_CATALOG)})
            return
        if path == "/api/foods/categories":
            self._send(200, {"items": []})
            return
        if path.startswith("/api/foods/barcode/"):
            self._error(404, "not_found", "Fixture barcode not found.")
            return
        if path == "/api/foods/search":
            summaries = {
                "qa-apple": {
                    "energy_kcal": "100",
                    "protein_g": "1",
                    "carbs_g": "20",
                    "fat_g": "0.5",
                    "fiber_g": "2",
                },
                "qa-pear": {
                    "energy_kcal": "80",
                    "protein_g": "0.5",
                    "carbs_g": "18",
                    "fat_g": "0.2",
                    "fiber_g": "3",
                },
            }
            items = []
            with self.state.lock:
                for product_id, base in PRODUCT_BASES.items():
                    if product_id in self.state.removed_food_ids:
                        continue
                    items.append(
                        {
                            "id": product_id,
                            "source": "local",
                            "source_id": product_id,
                            "barcode": "0123456789012" if product_id == "qa-apple" else None,
                            "name": base["name"],
                            "brand": "Native QA",
                            "categories": ["Fruit"],
                            "nutrition_summary": {"per_100g": summaries[product_id]},
                        }
                    )
            self._send(200, {"items": items})
            return
        if path in {"/api/foods/qa-apple", "/api/foods/qa-pear"}:
            product_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                if product_id in self.state.removed_food_ids:
                    self._error(404, "not_found", "Food not found.")
                    return
            base = PRODUCT_BASES[product_id]
            summary = {
                "energy_kcal": f"{base['energy']:g}",
                "protein_g": f"{base['protein']:g}",
                "carbs_g": f"{base['carbs']:g}",
                "fat_g": f"{base['fat']:g}",
                "fiber_g": "2",
            }
            self._send(
                200,
                {
                    "id": product_id,
                    "source": "local",
                    "source_id": product_id,
                    "visibility": "private",
                    "barcode": "0123456789012" if product_id == "qa-apple" else None,
                    "name": base["name"],
                    "brand": "Native QA",
                    "categories": ["Fruit"],
                    "default_quantity": "100",
                    "default_unit": "g",
                    "nutrition_summary": {"per_100g": summary},
                    "nutrients": [
                        {
                            "code": item["code"],
                            "amount_per_100g": item["amount"],
                            "unit": item["unit"],
                            "source": "fixture",
                            "confidence": "high",
                        }
                        for item in NUTRIENTS
                    ],
                    "servings": [
                        {"unit": "serving", "grams_per_unit": "100"}
                    ],
                    "allowed_units": [
                        {"code": "g", "name": "Gram", "kind": "mass"},
                        {"code": "serving", "name": "Serving", "kind": "serving"},
                    ],
                },
            )
            return
        if path.startswith("/api/foods/"):
            food_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                food = next(
                    (item for item in self.state.custom_foods if item["id"] == food_id),
                    None,
                )
                if food is not None:
                    self._send(200, copy.deepcopy(food))
                    return
            self._error(404, "not_found", "Food not found.")
            return
        if path == "/api/auth/api-keys":
            with self.state.lock:
                self._send(200, {"items": copy.deepcopy(self.state.api_keys)})
            return
        if path == "/api/meals":
            with self.state.lock:
                self._send(
                    200,
                    {
                        "items": [
                            decorate_meal(self.state, meal)
                            for meal in self.state.meals
                        ]
                    },
                )
            return
        if path.startswith("/api/meals/") and path.endswith("/nutrients"):
            meal_id = path.split("/")[-2]
            with self.state.lock:
                meal = next(
                    (item for item in self.state.meals if item["id"] == meal_id),
                    None,
                )
                if meal is None:
                    self._error(404, "not_found", "Meal not found.")
                    return
                decorated = decorate_meal(self.state, meal)
            if decorated.get("has_missing_components"):
                self._error(
                    409,
                    "missing_components",
                    "Meal contains unavailable ingredients.",
                )
                return
            query = self._query()
            amount = (query.get("amount") or ["100"])[0]
            unit = (query.get("unit") or ["g"])[0]
            summary = decorated.get("nutrition_summary") or {}
            self._send(
                200,
                {
                    "meal_id": meal_id,
                    "quantity": {"amount": amount, "unit": unit},
                    "nutrition_summary": summary,
                    "nutrients": [
                        {
                            "code": "ENERGY_KCAL",
                            "amount": str(summary.get("energy_kcal", "0")),
                            "unit": "kcal",
                        },
                        {
                            "code": "PROTEIN_G",
                            "amount": str(summary.get("protein_g", "0")),
                            "unit": "g",
                        },
                        {
                            "code": "CARBS_G",
                            "amount": str(summary.get("carbs_g", "0")),
                            "unit": "g",
                        },
                        {
                            "code": "FAT_G",
                            "amount": str(summary.get("fat_g", "0")),
                            "unit": "g",
                        },
                    ],
                },
            )
            return
        if path.startswith("/api/meals/"):
            meal_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                meal = next(
                    (item for item in self.state.meals if item["id"] == meal_id),
                    None,
                )
                if meal is None:
                    self._error(404, "not_found", "Meal not found.")
                    return
                self._send(200, decorate_meal(self.state, meal))
            return
        if path == "/api/nutrition/details":
            date = (self._query().get("date") or [self.state.historical])[0]
            self._send(
                200,
                {
                    "date": date,
                    "reference": {
                        "code": "native-qa-reference",
                        "name": "Native QA synthetic reference",
                        "authority": "Native QA",
                        "jurisdiction": "Test fixture",
                        "population_label": "Synthetic adult",
                        "source_url": "https://example.invalid/native-qa-reference",
                    },
                    "logged_items": 8,
                    "nutrients": [
                        {
                            "code": "ENERGY_KCAL",
                            "name": "Energy",
                            "section": "overview",
                            "known_amount": "800",
                            "unit": "kcal",
                            "reference_amount": "2000",
                            "guidance_kind": "informational",
                            "items_with_data": 8,
                            "coverage": "complete",
                            "status": "available",
                        },
                        {
                            "code": "PROTEIN_G",
                            "name": "Protein",
                            "section": "overview",
                            "known_amount": "8",
                            "unit": "g",
                            "reference_amount": "50",
                            "guidance_kind": "adequacy",
                            "items_with_data": 8,
                            "coverage": "partial",
                            "status": "below_reference",
                        },
                    ],
                },
            )
            return
        self._error(404, "not_found", f"No fixture route for {path}.")

    def do_POST(self) -> None:  # noqa: N802
        if getattr(self.server, "verbose", False):
            print(
                "QA_POST_HEADERS "
                + self.path
                + " "
                + json.dumps({k: v for k, v in self.headers.items()}, sort_keys=True),
                flush=True,
            )
        # Always drain Content-Length, including routes that ignore the body,
        # or the next keep-alive request line will be prefixed by leftover JSON.
        self._body()
        path = urlparse(self.path).path
        if path == "/__qa/reset":
            self._send(200, self.state.reset(self._json_body()))
            return
        if path == "/__qa/remove-food":
            body = self._json_body()
            food_id = str(body.get("id") or "")
            with self.state.lock:
                self.state.removed_food_ids.add(food_id)
            self._send(200, {"removed": food_id})
            return
        if path == "/api/auth/login":
            body = self._json_body()
            if (
                body.get("username") != FIXTURE_USERNAME
                or body.get("password") != FIXTURE_PASSWORD
            ):
                self._error(401, "invalid_credentials", "Invalid credentials.")
                return
            self._send(
                200,
                self.state.session(),
                headers=[
                    (
                        "Set-Cookie",
                        f"{COOKIE_NAME}={self.state.session_token}; "
                        "Path=/; HttpOnly; SameSite=Lax",
                    )
                ],
            )
            return
        if path == "/api/auth/logout":
            with self.state.lock:
                self.state.session_token = "qa-session-" + uuid.uuid4().hex
            self._send(204, None)
            return
        if not self._require_auth():
            return

        if path == "/api/ai/custom-food/draft":
            conversation = self._multipart_conversation()
            if conversation is None:
                self._error(400, "invalid_multipart", "Missing conversation multipart field.")
                return
            purpose = str(conversation.get("purpose") or "")
            if purpose not in {"custom_food", "ad_hoc_log"}:
                self._error(400, "invalid_purpose", "Unsupported assistant purpose.")
                return
            if not self.state.assistant_enabled:
                self._error(503, "assistant_disabled", "The assistant is disabled.")
                return
            with self.state.lock:
                self.state.assistant_draft_request_count += 1
                self.state.assistant_last_purpose = purpose
            draft = {
                "name": "Native QA AI Oats",
                "brand": "Native QA",
                "categories": ["Breakfast"],
                "default_quantity": "50",
                "default_unit": "g",
                "nutrients": [
                    {"code": "ENERGY_KCAL", "amount_per_100g": "380"},
                    {"code": "PROTEIN_G", "amount_per_100g": "13.5"},
                    {"code": "CARBS_G", "amount_per_100g": "60.25"},
                    {"code": "FAT_G", "amount_per_100g": "7.5"},
                ],
                "servings": [{"unit": "bowl", "grams_per_unit": "40"}],
            }
            payload = {
                "assistant_message": "Fixture draft ready for explicit Library review.",
                "status": "draft_ready",
                "draft": draft,
                "warnings": ["Fixture estimate; review before saving."],
            }
            if purpose == "ad_hoc_log":
                payload["suggested_log"] = {
                    "amount": "1",
                    "unit": "bowl",
                    "total_weight_grams": "40",
                }
            else:
                payload["suggested_log"] = None
            self._send(200, payload)
            return
        if path == "/api/logs/last-used":
            with self.state.lock:
                self._send(200, {"items": copy.deepcopy(self.state.recent_items)})
            return
        if path == "/api/logs/batch":
            body = self._json_body()
            key = str(body.get("idempotency_key") or "")
            items = body.get("items") or []
            with self.state.lock:
                self.state.log_post_attempts += 1
                if key and key in self.state.batch_idempotency:
                    ids = self.state.batch_idempotency[key]
                    logs = [
                        copy.deepcopy(log)
                        for log_id in ids
                        for log in self.state.logs
                        if log["id"] == log_id
                    ]
                    self._send(200, {"items": logs})
                    return
                created: list[dict] = []
                for index, line in enumerate(items):
                    item = line.get("item") or {}
                    quantity = line.get("quantity") or {}
                    item_id = str(item.get("id") or "qa-apple")
                    name = (
                        "Native QA Apple"
                        if item_id == "qa-apple"
                        else "Native QA Pear"
                        if item_id == "qa-pear"
                        else str(item.get("name") or "Native QA meal")
                    )
                    log = make_log(
                        f"batch-log-{len(self.state.logs)+index+1}",
                        str(line.get("log_date") or self.state.today),
                        str(line.get("meal_slot") or "breakfast"),
                        name,
                        amount=str(quantity.get("amount") or "100"),
                        notes=line.get("notes"),
                    )
                    if item.get("type") == "meal":
                        log["item"] = {
                            "type": "meal",
                            "id": item_id,
                            "name": name,
                        }
                    self.state.logs.append(log)
                    created.append(log)
                if key:
                    self.state.batch_idempotency[key] = [log["id"] for log in created]
                self._send(201, {"items": created})
            return
        if path == "/api/logs/ad-hoc":
            body = self._json_body()
            if getattr(self.server, "verbose", False):
                print("QA_ADHOC_POST " + json.dumps(body, sort_keys=True), flush=True)
            key = str(body.get("idempotency_key") or "")
            quantity = body.get("quantity") or {}
            with self.state.lock:
                self.state.log_post_attempts += 1
                if key and key in self.state.idempotency:
                    existing = next(
                        (
                            log
                            for log in self.state.logs
                            if log["id"] == self.state.idempotency[key]
                        ),
                        None,
                    )
                    if existing is not None:
                        self._send(200, existing)
                        return
                log = make_log(
                    "adhoc-log-" + uuid.uuid4().hex[:8],
                    str(body.get("log_date") or self.state.today),
                    str(body.get("meal_slot") or "breakfast"),
                    str(body.get("name") or "Native QA ad-hoc"),
                    amount=str(quantity.get("amount") or "100"),
                    unit=str(quantity.get("unit") or "g"),
                    notes=body.get("notes"),
                )
                log["item"] = {
                    "type": "ad_hoc",
                    "name": str(body.get("name") or "Native QA ad-hoc"),
                    "brand": body.get("brand"),
                }
                log["nutrients"] = [
                    {
                        "code": str(n.get("code") or "ENERGY_KCAL"),
                        "amount": str(n.get("amount") or "0"),
                        "unit": str(n.get("unit") or ""),
                    }
                    for n in (body.get("nutrients") or [])
                ] or log["nutrients"]
                self.state.logs.append(log)
                if key:
                    self.state.idempotency[key] = log["id"]
                self._send(201, log)
            return
        if path == "/api/logs":
            body = self._json_body()
            if getattr(self.server, "verbose", False):
                print("QA_LOG_POST " + json.dumps(body, sort_keys=True), flush=True)
            key = body.get("idempotency_key") or ""
            with self.state.lock:
                self.state.log_post_attempts += 1
                if self.state.log_post_mode == "conflict":
                    self._error(
                        409,
                        "idempotency_conflict",
                        "Injected conflict for the same idempotency key.",
                    )
                    return
                if key and key in self.state.idempotency:
                    log_id = self.state.idempotency[key]
                    existing = next(
                        (item for item in self.state.logs if item["id"] == log_id),
                        None,
                    )
                    if existing is not None:
                        self._send(200, existing)
                        return
                if self.state.log_post_mode == "fail_once" and key not in self.state.failed_once_keys:
                    self.state.failed_once_keys.add(key)
                    self._error(
                        503,
                        "temporarily_unavailable",
                        "Injected ambiguous failure; retry the same key.",
                    )
                    return
                item = body.get("item") or {}
                quantity = body.get("quantity") or {}
                amount = str(quantity.get("amount") or "100")
                item_type = str(item.get("type") or "product")
                item_id = str(item.get("id") or "qa-apple")
                custom = next(
                    (food for food in self.state.custom_foods if food["id"] == item_id),
                    None,
                )
                name = str(
                    item.get("name")
                    or (custom or {}).get("name")
                    or ("Native QA Meal" if item_type == "meal" else "Native QA Apple")
                )
                log = make_log(
                    "new-log-" + uuid.uuid4().hex[:8],
                    str(body.get("log_date") or self.state.today),
                    str(body.get("meal_slot") or "breakfast"),
                    name,
                    amount=amount,
                    unit=str(quantity.get("unit") or "g"),
                    notes=body.get("notes"),
                )
                log["item"] = {
                    "type": item_type,
                    "id": item_id,
                    "name": name,
                }
                brand = item.get("brand") or (custom or {}).get("brand")
                if brand is not None:
                    log["item"]["brand"] = brand
                self.state.logs.append(log)
                if key:
                    self.state.idempotency[key] = log["id"]
                if getattr(self.server, "verbose", False):
                    print("QA_LOG_RESPONSE " + json.dumps(log, sort_keys=True), flush=True)
                self._send(201, log)
            return
        if path == "/api/meals":
            body = self._json_body()
            with self.state.lock:
                missing = [
                    str((item.get("item") or {}).get("id") or "")
                    for item in (body.get("components") or [])
                    if product_name(
                        self.state,
                        str((item.get("item") or {}).get("id") or ""),
                    )
                    is None
                ]
                if missing:
                    self._error(
                        409,
                        "missing_components",
                        "Meal contains unavailable ingredients.",
                    )
                    return
                meal_id = "qa-meal-" + uuid.uuid4().hex[:8]
                meal = make_meal(self.state, meal_id, body)
                self.state.meal_create_count += 1
                self.state.meals.append(meal)
                self._send(201, decorate_meal(self.state, meal))
            return
        if path == "/api/foods/custom":
            body = self._json_body()
            with self.state.lock:
                product_id = "qa-custom-" + uuid.uuid4().hex[:8]
                product = make_custom_product(product_id, body)
                self.state.custom_food_create_count += 1
                self.state.custom_foods.append(product)
                self._send(201, {"id": product_id})
            return
        if path == "/api/auth/api-keys":
            body = self._json_body()
            with self.state.lock:
                key_id = "qa-api-key-" + uuid.uuid4().hex[:8]
                token = "qa_" + uuid.uuid4().hex
                record = {
                    "id": key_id,
                    "name": str(body.get("name") or "Native QA key"),
                    "token_hint": token[:10] + "…",
                    "scope": str(body.get("scope") or "read"),
                    "created_at": "2026-11-19T12:00:00Z",
                    "last_used_at": None,
                    "expires_at": None,
                }
                self.state.api_keys.append(record)
                self._send(201, {**record, "token": token})
            return
        self._error(404, "not_found", f"No fixture route for {path}.")

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if not self._require_auth():
            return
        if path == "/api/goal":
            body = self._json_body()
            with self.state.lock:
                self.state.goal.update(
                    {
                        "requested_date": body.get("local_date", self.state.today),
                        "effective_from": body.get("local_date", self.state.today),
                        "source": "saved",
                        "calorie_target": body.get(
                            "calorie_target", self.state.goal["calorie_target"]
                        ),
                        "protein_target_g": body.get(
                            "protein_target_g", self.state.goal["protein_target_g"]
                        ),
                        "carbs_target_g": body.get(
                            "carbs_target_g", self.state.goal["carbs_target_g"]
                        ),
                        "fat_target_g": body.get(
                            "fat_target_g", self.state.goal["fat_target_g"]
                        ),
                    }
                )
                self._send(200, copy.deepcopy(self.state.goal))
            return
        if path == "/api/diary-preferences":
            body = self._json_body()
            with self.state.lock:
                slots = body.get("enabled_meal_slots")
                if isinstance(slots, list):
                    self.state.enabled_slots = [str(slot) for slot in slots]
                self._send(200, {"enabled_meal_slots": list(self.state.enabled_slots)})
            return
        if path.startswith("/api/meals/"):
            meal_id = path.rsplit("/", 1)[-1]
            body = self._json_body()
            with self.state.lock:
                existing = next(
                    (item for item in self.state.meals if item["id"] == meal_id),
                    None,
                )
                if existing is None:
                    self._error(404, "not_found", "Meal not found.")
                    return
                missing = [
                    str((item.get("item") or {}).get("id") or "")
                    for item in (body.get("components") or [])
                    if product_name(
                        self.state,
                        str((item.get("item") or {}).get("id") or ""),
                    )
                    is None
                ]
                if missing:
                    self._error(
                        409,
                        "missing_components",
                        "Meal contains unavailable ingredients.",
                    )
                    return
                updated = make_meal(self.state, meal_id, body, existing=existing)
                self.state.meal_update_count += 1
                self.state.meals = [
                    updated if item["id"] == meal_id else item
                    for item in self.state.meals
                ]
                self._send(200, decorate_meal(self.state, updated))
            return
        if path.startswith("/api/foods/custom/"):
            product_id = path.rsplit("/", 1)[-1]
            body = self._json_body()
            with self.state.lock:
                for index, food in enumerate(self.state.custom_foods):
                    if food["id"] == product_id:
                        updated = make_custom_product(product_id, body)
                        self.state.custom_food_update_count += 1
                        self.state.custom_foods[index] = updated
                        self._send(200, {"id": product_id})
                        return
            self._error(404, "not_found", "Custom food not found.")
            return
        if path.startswith("/api/logs/"):
            log_id = path.rsplit("/", 1)[-1]
            body = self._json_body()
            with self.state.lock:
                log = next(
                    (item for item in self.state.logs if item["id"] == log_id),
                    None,
                )
                if log is None:
                    self._error(404, "not_found", "Log not found.")
                    return
                quantity = body.get("quantity") or log["quantity"]
                amount = str(quantity.get("amount") or "100")
                log["quantity"] = {
                    "amount": amount,
                    "unit": str(quantity.get("unit") or "g"),
                }
                log["nutrients"] = nutrient_amounts(float(amount))
                if "meal_slot" in body:
                    log["meal_slot"] = body["meal_slot"]
                if "notes" in body:
                    log["notes"] = body["notes"]
                self._send(200, log)
            return
        self._error(404, "not_found", f"No fixture route for {path}.")

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if not self._require_auth():
            return
        if path.startswith("/api/auth/api-keys/"):
            key_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                before = len(self.state.api_keys)
                self.state.api_keys = [
                    item for item in self.state.api_keys if item["id"] != key_id
                ]
                removed = len(self.state.api_keys) != before
            if removed:
                self._send(204, None)
            else:
                self._error(404, "not_found", "API key not found.")
            return
        if path.startswith("/api/foods/custom/"):
            product_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                before = len(self.state.custom_foods)
                self.state.custom_foods = [
                    food for food in self.state.custom_foods if food["id"] != product_id
                ]
                removed = len(self.state.custom_foods) != before
                if removed:
                    self.state.custom_food_delete_count += 1
            if removed:
                self._send(204, None)
            else:
                self._error(404, "not_found", "Custom food not found.")
            return
        if path.startswith("/api/logs/"):
            log_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                before = len(self.state.logs)
                self.state.logs = [
                    item for item in self.state.logs if item["id"] != log_id
                ]
                removed = len(self.state.logs) != before
            if removed:
                self._send(204, None)
            else:
                self._error(404, "not_found", "Log not found.")
            return
        if path.startswith("/api/meals/"):
            meal_id = path.rsplit("/", 1)[-1]
            with self.state.lock:
                before = len(self.state.meals)
                self.state.meals = [
                    item for item in self.state.meals if item["id"] != meal_id
                ]
                removed = len(self.state.meals) != before
                if removed:
                    self.state.meal_delete_count += 1
            if removed:
                self._send(204, None)
            else:
                self._error(404, "not_found", "Meal not found.")
            return
        self._error(404, "not_found", f"No fixture route for {path}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3932)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.host != "127.0.0.1":
        raise SystemExit("NativeCompletionQAMockServer must bind 127.0.0.1 only.")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = FixtureState()  # type: ignore[attr-defined]
    server.verbose = args.verbose  # type: ignore[attr-defined]
    print(
        f"NativeCompletionQAMockServer listening on http://{args.host}:{args.port}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
