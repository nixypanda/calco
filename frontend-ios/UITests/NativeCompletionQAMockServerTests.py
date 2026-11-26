#!/usr/bin/env python3
"""Focused contract tests for NativeCompletionQAMockServer.

Run directly:
  python3 frontend-ios/UITests/NativeCompletionQAMockServerTests.py
"""

from __future__ import annotations

import json
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

import NativeCompletionQAMockServer as mock


class MockContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), mock.Handler)
        cls.server.state = mock.FixtureState()  # type: ignore[attr-defined]
        cls.server.verbose = False  # type: ignore[attr-defined]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.cookie = ""

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self) -> None:
        response = self.request("POST", "/__qa/reset", {"today": "2026-11-19"})
        self.assertEqual(response[0], 200)
        login = self.request(
            "POST",
            "/api/auth/login",
            {"username": mock.FIXTURE_USERNAME, "password": mock.FIXTURE_PASSWORD},
        )
        self.assertEqual(login[0], 200)
        self.cookie = login[2].headers["Set-Cookie"].split(";", 1)[0]

    def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        headers: dict[str, str] | None = None,
        timeout: float = 5.0,
    ) -> tuple[int, dict, object]:
        data = None if body is None else json.dumps(body).encode()
        return self.request_raw(
            method,
            path,
            data,
            "application/json" if data is not None else None,
            headers,
            timeout,
        )

    def request_raw(
        self,
        method: str,
        path: str,
        data: bytes | None,
        content_type: str | None,
        headers: dict[str, str] | None = None,
        timeout: float = 5.0,
    ) -> tuple[int, dict, object]:
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Accept", "application/json")
        if content_type is not None:
            request.add_header("Content-Type", content_type)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        if self.cookie:
            request.add_header("Cookie", self.cookie)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                return (
                    response.status,
                    json.loads(raw) if raw else {},
                    response,
                )
        except urllib.error.HTTPError as error:
            raw = error.read()
            result = (error.code, json.loads(raw) if raw else {}, error)
            error.close()
            return result

    def multipart_draft(
        self,
        purpose: str,
        text: str = "draft this food",
    ) -> tuple[int, dict, object]:
        boundary = "contract-boundary-" + uuid.uuid4().hex
        conversation = json.dumps(
            {
                "purpose": purpose,
                "turns": [{"role": "user", "text": text}],
            }
        )
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="conversation"\r\n'
            "Content-Type: application/json\r\n\r\n"
            f"{conversation}\r\n"
            f"--{boundary}--\r\n"
        ).encode()
        return self.request_raw(
            "POST",
            "/api/ai/custom-food/draft",
            body,
            f"multipart/form-data; boundary={boundary}",
        )

    def login(self) -> None:
        login = self.request(
            "POST",
            "/api/auth/login",
            {"username": mock.FIXTURE_USERNAME, "password": mock.FIXTURE_PASSWORD},
        )
        self.assertEqual(login[0], 200)
        self.cookie = login[2].headers["Set-Cookie"].split(";", 1)[0]

    def state(self) -> dict:
        return self.request("GET", "/__qa/state")[1]

    @staticmethod
    def batch_body() -> dict:
        base = {
            "log_date": "2026-11-19",
            "meal_slot": "breakfast",
            "item": {"type": "product", "id": "qa-apple"},
            "quantity": {"amount": "100", "unit": "g"},
        }
        return {
            "items": [
                base,
                {
                    **base,
                    "meal_slot": "lunch",
                    "item": {"type": "product", "id": "qa-pear"},
                },
            ]
        }

    def wait_for_in_flight(self, expected: int, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            snapshot = self.state()
            if snapshot["log_batch_post_in_flight"] == expected:
                return snapshot
            if time.monotonic() >= deadline:
                self.fail(f"Batch in-flight never reached {expected}: {snapshot}")
            time.sleep(0.01)

    def test_session_identity_and_profile_are_distinct_valid_uuids(self) -> None:
        status, payload, _ = self.request("GET", "/api/auth/session")
        self.assertEqual(status, 200)
        identity = payload["identity"]["id"]
        profile = payload["profile"]["id"]
        self.assertNotEqual(identity, profile)
        uuid.UUID(identity)
        uuid.UUID(profile)
        self.assertEqual(profile, mock.FIXTURE_PROFILE_ID)

    def test_protected_route_requires_session_cookie(self) -> None:
        saved = self.cookie
        self.cookie = ""
        try:
            status, payload, _ = self.request("GET", "/api/goal")
        finally:
            self.cookie = saved
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "unauthorized")
        status, _, _ = self.request("GET", "/api/goal")
        self.assertEqual(status, 200)

    def test_goal_save_is_effective_only_from_its_local_date(self) -> None:
        historical = "2026-11-18"  # reset(today=2026-11-19) sets historical -1 day
        status, baseline, _ = self.request("GET", f"/api/goal?date={historical}")
        self.assertEqual(status, 200)
        self.assertEqual(baseline["calorie_target"], 2000)
        self.assertIsNone(baseline["effective_from"])

        status, saved, _ = self.request(
            "PUT",
            "/api/goal",
            {"local_date": "2026-11-19", "calorie_target": 2230},
        )
        self.assertEqual(status, 200)
        self.assertEqual(saved["effective_from"], "2026-11-19")

        status, before, _ = self.request("GET", f"/api/goal?date={historical}")
        self.assertEqual(status, 200)
        self.assertEqual(
            before["calorie_target"],
            2000,
            "A save effective today must not rewrite an earlier day's goal.",
        )
        status, today, _ = self.request("GET", "/api/goal?date=2026-11-19")
        self.assertEqual(today["calorie_target"], 2230)
        self.assertEqual(today["effective_from"], "2026-11-19")

    def test_capabilities_endpoint_is_absent(self) -> None:
        status, payload, _ = self.request("GET", "/api/capabilities")
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"]["code"], "not_found")

    def test_legacy_account_binding_header_is_rejected(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/goal",
            headers={mock.LEGACY_ACCOUNT_HEADER: mock.FIXTURE_PROFILE_ID},
        )
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "unexpected_account_header")

    def test_nutrient_catalog_has_all_four_required_definitions(self) -> None:
        status, payload, _ = self.request("GET", "/api/nutrients")
        self.assertEqual(status, 200)
        rows = {row["code"]: row for row in payload["items"]}
        expected = {
            "ENERGY_KCAL": "kcal",
            "PROTEIN_G": "g",
            "CARBS_G": "g",
            "FAT_G": "g",
        }
        for code, unit in expected.items():
            self.assertIn(code, rows)
            self.assertEqual(rows[code]["unit"], unit)

    def test_custom_food_create_detail_and_delete_keep_nutrients(self) -> None:
        body = {
            "name": "Contract Custom Food",
            "brand": "Contract",
            "categories": ["fixture"],
            "default_quantity": 100,
            "default_unit": "g",
            "nutrients": [
                {"code": "ENERGY_KCAL", "amount_per_100g": 100},
                {"code": "PROTEIN_G", "amount_per_100g": 10},
                {"code": "CARBS_G", "amount_per_100g": 20},
                {"code": "FAT_G", "amount_per_100g": 5},
            ],
            "servings": [{"unit": "pack", "grams_per_unit": 80}],
        }
        status, payload, _ = self.request(
            "POST",
            "/api/foods/custom",
            body,
        )
        self.assertEqual(status, 201)
        food_id = payload["id"]
        status, detail, _ = self.request(
            "GET",
            f"/api/foods/{food_id}",
        )
        self.assertEqual(status, 200)
        self.assertEqual(detail["name"], "Contract Custom Food")
        amounts = {
            row["code"]: (row["amount_per_100g"], row["unit"])
            for row in detail["nutrients"]
        }
        self.assertEqual(amounts["ENERGY_KCAL"], ("100", "kcal"))
        self.assertEqual(amounts["PROTEIN_G"], ("10", "g"))
        self.assertEqual(amounts["CARBS_G"], ("20", "g"))
        self.assertEqual(amounts["FAT_G"], ("5", "g"))
        self.assertEqual(
            detail["servings"],
            [{"unit": "pack", "grams_per_unit": "80"}],
        )
        status, _, _ = self.request(
            "DELETE",
            f"/api/foods/custom/{food_id}",
        )
        self.assertEqual(status, 204)
        state = self.request("GET", "/__qa/state")[1]
        self.assertEqual(state["custom_food_create_count"], 1)
        self.assertEqual(state["custom_food_delete_count"], 1)
        self.assertEqual(state["custom_food_count"], 0)

    def test_assistant_status_and_multipart_drafts_are_purpose_exact(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/ai/food-assistant/status",
        )
        self.assertEqual(status, 200)
        self.assertFalse(payload["enabled"])

        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "assistant_enabled": True},
        )
        self.assertEqual(reset[0], 200)
        self.login()
        status, payload, _ = self.request(
            "GET",
            "/api/ai/food-assistant/status",
        )
        self.assertEqual(status, 200)
        self.assertTrue(payload["enabled"])

        status, draft, _ = self.multipart_draft("custom_food")
        self.assertEqual(status, 200)
        self.assertEqual(draft["status"], "draft_ready")
        self.assertIsNone(draft["suggested_log"])
        amounts = {
            row["code"]: row["amount_per_100g"]
            for row in draft["draft"]["nutrients"]
        }
        self.assertEqual(
            amounts,
            {
                "ENERGY_KCAL": "380",
                "PROTEIN_G": "13.5",
                "CARBS_G": "60.25",
                "FAT_G": "7.5",
            },
        )
        self.assertEqual(
            draft["draft"]["servings"],
            [{"unit": "bowl", "grams_per_unit": "40"}],
        )
        self.assertFalse(draft["warnings"] == [])

        status, ad_hoc, _ = self.multipart_draft("ad_hoc_log")
        self.assertEqual(status, 200)
        self.assertEqual(
            ad_hoc["suggested_log"],
            {"amount": "1", "unit": "bowl", "total_weight_grams": "40"},
        )
        state = self.request("GET", "/__qa/state")[1]
        self.assertEqual(state["assistant_draft_request_count"], 2)
        self.assertEqual(state["assistant_last_purpose"], "ad_hoc_log")
        self.assertEqual(state["custom_food_create_count"], 0)
        self.assertEqual(state["log_post_attempts"], 0)

    def test_meal_crud_is_faithful(self) -> None:
        body = {
            "name": "Contract Meal",
            "notes": "contract notes",
            "total_quantity": {"amount": "150", "unit": "g"},
            "components": [
                {
                    "item": {"type": "product", "id": "qa-apple"},
                    "quantity": {"amount": "100", "unit": "g"},
                }
            ],
        }
        status, meal, _ = self.request(
            "POST",
            "/api/meals",
            body,
        )
        self.assertEqual(status, 201)
        meal_id = meal["id"]
        self.assertEqual(meal["name"], "Contract Meal")
        self.assertNotIn("has_missing_components", meal)
        status, detail, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}",
        )
        self.assertEqual(status, 200)
        self.assertEqual(detail["notes"], "contract notes")
        status, preview, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}/nutrients?amount=100&unit=g",
        )
        self.assertEqual(status, 200)
        self.assertEqual(preview["meal_id"], meal_id)

        repaired = dict(body)
        repaired["notes"] = "updated contract notes"
        status, updated, _ = self.request(
            "PUT",
            f"/api/meals/{meal_id}",
            repaired,
        )
        self.assertEqual(status, 200)
        self.assertEqual(updated["notes"], "updated contract notes")
        status, preview, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}/nutrients?amount=100&unit=g",
        )
        self.assertEqual(status, 200)
        status, _, _ = self.request(
            "DELETE",
            f"/api/meals/{meal_id}",
        )
        self.assertEqual(status, 204)
        state = self.request("GET", "/__qa/state")[1]
        self.assertEqual(state["meal_create_count"], 1)
        self.assertEqual(state["meal_update_count"], 1)
        self.assertEqual(state["meal_delete_count"], 1)
        self.assertEqual(state["meal_count"], 1)

    def test_normal_log_create_batch_and_ad_hoc_are_unkeyed(self) -> None:
        log_body = {
            "log_date": "2026-11-19",
            "meal_slot": "breakfast",
            "item": {"type": "product", "id": "qa-apple"},
            "quantity": {"amount": "100", "unit": "g"},
        }
        status, created, _ = self.request("POST", "/api/logs", log_body)
        self.assertEqual(status, 201)
        self.assertEqual(created["item"]["id"], "qa-apple")
        status, batch, _ = self.request(
            "POST",
            "/api/logs/batch",
            {
                "items": [
                    log_body,
                    {
                        **log_body,
                        "meal_slot": "lunch",
                        "item": {"type": "product", "id": "qa-pear"},
                    },
                ]
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(len(batch["items"]), 2)
        status, ad_hoc, _ = self.request(
            "POST",
            "/api/logs/ad-hoc",
            {
                "log_date": "2026-11-19",
                "meal_slot": "snack",
                "name": "Contract ad hoc",
                "quantity": {"amount": "1", "unit": "serving"},
                "nutrients": [
                    {"code": "ENERGY_KCAL", "amount": "50", "unit": "kcal"}
                ],
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(ad_hoc["item"]["type"], "ad_hoc")
        state = self.request("GET", "/__qa/state")[1]
        self.assertEqual(state["log_post_attempts"], 3)
        self.assertEqual(state["log_count"], 12)
        self.assertNotIn("idempotency_keys", state)

    def test_fail_once_returns_ordinary_503_then_accepts_resubmission(self) -> None:
        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "log_post": "fail_once"},
        )
        self.assertEqual(reset[0], 200)
        self.login()
        log_body = {
            "log_date": "2026-11-19",
            "meal_slot": "breakfast",
            "item": {"type": "product", "id": "qa-apple"},
            "quantity": {"amount": "100", "unit": "g"},
        }
        status, payload, _ = self.request("POST", "/api/logs", log_body)
        self.assertEqual(status, 503)
        self.assertEqual(payload["error"]["code"], "temporarily_unavailable")
        after_failure = self.request("GET", "/__qa/state")[1]
        self.assertEqual(after_failure["log_post_attempts"], 1)
        self.assertEqual(after_failure["log_count"], 8)

        status, created, _ = self.request("POST", "/api/logs", log_body)
        self.assertEqual(status, 201)
        self.assertTrue(created["id"].startswith("new-log-"))
        final = self.request("GET", "/__qa/state")[1]
        self.assertEqual(final["log_post_attempts"], 2)
        self.assertEqual(final["log_count"], 9)

    def test_login_session_logout_use_cookie_session(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/auth/session",
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["identity"]["username"], mock.FIXTURE_USERNAME)
        status, _, _ = self.request("POST", "/api/auth/logout")
        self.assertEqual(status, 204)
        status, payload, _ = self.request("GET", "/api/auth/session")
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "not_found")


    # MARK: - Opt-in batch write controls (defaults unchanged)

    def test_default_reset_keeps_batch_success_and_single_route_behavior(self) -> None:
        health = self.request("GET", "/__qa/health")[1]
        self.assertEqual(
            health["capabilities"],
            {
                "fail_batch_once": True,
                "log_post_hold": True,
                "latest_slots_read_401": True,
            },
        )
        self.assertEqual(
            health["injected_transient_message"], mock.TRANSIENT_FAILURE_MESSAGE
        )

        baseline = self.state()
        self.assertFalse(baseline["fail_batch_once"])
        self.assertFalse(baseline["log_post_hold"])
        self.assertEqual(baseline["log_batch_post_commits"], 0)
        self.assertEqual(baseline["log_batch_post_in_flight"], 0)
        self.assertEqual(baseline["log_post_attempts"], 0)
        self.assertEqual(baseline["log_count"], 8)

        status, batch, _ = self.request("POST", "/api/logs/batch", self.batch_body())
        self.assertEqual(status, 201)
        self.assertEqual([row["id"] for row in batch["items"]],
                         ["batch-log-9", "batch-log-11"])
        after_batch = self.state()
        self.assertEqual(after_batch["log_post_attempts"], 1)
        self.assertEqual(after_batch["log_batch_post_commits"], 1)
        self.assertEqual(after_batch["log_batch_post_in_flight"], 0)
        self.assertEqual(after_batch["log_count"], 10)

        # The single route keeps its old behavior; only the batch route opted in.
        status, single, _ = self.request(
            "POST", "/api/logs", self.batch_body()["items"][0]
        )
        self.assertEqual(status, 201)
        self.assertTrue(single["id"].startswith("new-log-"))
        after_single = self.state()
        self.assertEqual(after_single["log_post_attempts"], 2)
        self.assertEqual(after_single["log_batch_post_commits"], 1)
        self.assertEqual(after_single["log_count"], 11)

    def test_fail_batch_once_fails_once_then_explicit_retry_commits(self) -> None:
        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "fail_batch_once": True},
        )
        self.assertEqual(reset[0], 200)
        self.login()

        status, payload, _ = self.request(
            "POST", "/api/logs/batch", self.batch_body()
        )
        self.assertEqual(status, 503)
        self.assertEqual(payload["error"]["code"], "temporarily_unavailable")
        self.assertEqual(
            payload["error"]["message"], mock.TRANSIENT_FAILURE_MESSAGE
        )
        failed = self.state()
        self.assertEqual(failed["log_post_attempts"], 1)
        self.assertEqual(failed["log_batch_post_commits"], 0)
        self.assertEqual(failed["log_batch_post_in_flight"], 0)
        self.assertEqual(failed["log_count"], 8)
        self.assertFalse(failed["batch_fail_once_armed"])

        status, batch, _ = self.request("POST", "/api/logs/batch", self.batch_body())
        self.assertEqual(status, 201)
        self.assertEqual([row["id"] for row in batch["items"]],
                         ["batch-log-9", "batch-log-11"])
        final = self.state()
        self.assertEqual(final["log_post_attempts"], 2)
        self.assertEqual(final["log_batch_post_commits"], 1)
        self.assertEqual(final["log_count"], 10)

    def test_log_post_hold_parks_batch_until_release_then_commits(self) -> None:
        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "log_post_hold": True},
        )
        self.assertEqual(reset[0], 200)
        self.login()

        outcome: dict[str, tuple[int, dict, object]] = {}

        def worker() -> None:
            outcome["response"] = self.request(
                "POST", "/api/logs/batch", self.batch_body(), timeout=25
            )

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        parked = self.wait_for_in_flight(1)
        self.assertEqual(parked["log_post_attempts"], 1)
        self.assertEqual(parked["log_batch_post_commits"], 0)
        self.assertEqual(parked["log_count"], 8)
        self.assertTrue(parked["log_post_hold"])
        self.assertTrue(thread.is_alive())

        status, release, _ = self.request("POST", "/__qa/log-post/release")
        self.assertEqual(status, 200)
        self.assertEqual(release["released"], 1)
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "The parked batch POST did not resume.")

        status, batch, _ = outcome["response"]
        self.assertEqual(status, 201)
        self.assertEqual(len(batch["items"]), 2)
        final = self.state()
        self.assertEqual(final["log_post_attempts"], 1)
        self.assertEqual(final["log_batch_post_commits"], 1)
        self.assertEqual(final["log_batch_post_in_flight"], 0)
        self.assertEqual(final["log_count"], 10)

    def test_reset_during_hold_aborts_old_gate_without_writing_new_state(self) -> None:
        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "log_post_hold": True},
        )
        self.assertEqual(reset[0], 200)
        self.login()
        old_epoch = self.state()["fixture_epoch"]

        outcome: dict[str, tuple[int, dict, object]] = {}

        def worker() -> None:
            outcome["response"] = self.request(
                "POST", "/api/logs/batch", self.batch_body(), timeout=25
            )

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        self.wait_for_in_flight(1)

        fresh = self.request("POST", "/__qa/reset", {"today": "2026-11-19"})
        self.assertEqual(fresh[0], 200)
        self.login()
        thread.join(timeout=10)
        self.assertFalse(thread.is_alive(), "Reset did not release the old gate.")

        status, payload, _ = outcome["response"]
        self.assertEqual(status, 503, "A parked request must fail closed after reset.")
        self.assertEqual(payload["error"]["code"], "temporarily_unavailable")
        final = self.state()
        self.assertGreater(final["fixture_epoch"], old_epoch)
        self.assertEqual(final["log_post_attempts"], 0)
        self.assertEqual(final["log_batch_post_commits"], 0)
        self.assertEqual(final["log_batch_post_in_flight"], 0)
        self.assertEqual(final["log_count"], 8)
        self.assertTrue(all(row.startswith("hist-log-") for row in final["log_ids"]))

    # ---- Opt-in latest-slots 401 diagnostics (new contracts only) ----

    LATEST_DIAGNOSTIC_KEYS = (
        "latest_slots_read_attempts",
        "latest_slots_401_armed",
        "latest_slots_401_consumed",
    )

    @classmethod
    def canonical_state(cls, state: dict) -> str:
        return json.dumps(state, sort_keys=True, separators=(",", ":"))

    @classmethod
    def domain_state(cls, state: dict) -> dict:
        return {key: value for key, value in state.items()
                if key not in cls.LATEST_DIAGNOSTIC_KEYS}

    def test_latest_slots_read_401_capability_is_advertised(self) -> None:
        status, payload, _ = self.request("GET", "/__qa/health")
        self.assertEqual(status, 200)
        self.assertEqual(payload["fixture"], "native-completion-qa")
        capabilities = payload["capabilities"]
        self.assertTrue(capabilities["fail_batch_once"])
        self.assertTrue(capabilities["log_post_hold"])
        self.assertTrue(capabilities["latest_slots_read_401"],
                        "The required one-shot 401 capability must be advertised.")

    def test_latest_slots_read_401_default_off_preserves_canonical_state(self) -> None:
        baseline = self.state()
        for key in self.LATEST_DIAGNOSTIC_KEYS:
            self.assertNotIn(key, baseline, "Diagnostics must be opt-in only.")
        self.assertEqual(baseline["log_count"], 8)
        self.assertEqual(baseline["log_post_attempts"], 0)

        status, payload, _ = self.request("GET", "/api/logs/latest-slots")
        self.assertEqual(status, 200)
        slots = payload["slots"]
        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0]["source_date"], "2026-11-18")
        self.assertEqual(slots[0]["meal_slot"], "breakfast")
        self.assertEqual([row["id"] for row in slots[0]["items"]],
                         ["hist-log-001", "hist-log-002"])

        after = self.state()
        for key in self.LATEST_DIAGNOSTIC_KEYS:
            self.assertNotIn(key, after, "A normal read must not expose diagnostics.")
        self.assertEqual(self.canonical_state(after), self.canonical_state(baseline),
                         "A normal latest-slots read changed the canonical fixture state.")

    def test_latest_slots_read_401_one_shot_error_then_exact_breakfast(self) -> None:
        reset = self.request(
            "POST", "/__qa/reset", {"today": "2026-11-19", "latest_slots_401_once": True}
        )
        self.assertEqual(reset[0], 200)
        self.login()
        baseline = self.state()
        self.assertTrue(baseline["latest_slots_401_armed"])
        self.assertEqual(baseline["latest_slots_read_attempts"], 0)
        self.assertEqual(baseline["latest_slots_401_consumed"], 0)
        domain_before = self.domain_state(baseline)
        self.assertEqual(domain_before["log_count"], 8)

        status, payload, _ = self.request("GET", "/api/logs/latest-slots")
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "unauthorized")
        self.assertEqual(payload["error"]["message"], "Sign in required.")

        after_fault = self.state()
        self.assertFalse(after_fault["latest_slots_401_armed"])
        self.assertEqual(after_fault["latest_slots_401_consumed"], 1)
        self.assertEqual(after_fault["latest_slots_read_attempts"], 1)
        self.assertEqual(self.domain_state(after_fault), domain_before,
                         "The 401 fault mutated the logged fixture baseline.")
        direct = type(self).server.state  # type: ignore[attr-defined]
        self.assertEqual(direct.enabled_slots, [
            "breakfast", "lunch", "dinner", "snack", "late_night_snack",
        ], "The 401 fault changed the slot preferences.")
        self.assertEqual(direct.goal["calorie_target"], 2000)
        self.assertEqual(direct.goal["protein_target_g"], 150)
        self.assertEqual(direct.goal["carbs_target_g"], 250)
        self.assertEqual(direct.goal["fat_target_g"], 70)
        self.assertEqual([row["id"] for row in direct.logs],
                         [f"hist-log-{index:03d}" for index in range(1, 9)])

        # The fault handler must not rotate the session or the domain.
        session_status, session, _ = self.request("GET", "/api/auth/session")
        self.assertEqual(session_status, 200)
        self.assertEqual(session["identity"]["username"], mock.FIXTURE_USERNAME)

        status, payload, _ = self.request("GET", "/api/logs/latest-slots")
        self.assertEqual(status, 200)
        slots = payload["slots"]
        self.assertEqual(len(slots), 1)
        self.assertEqual(slots[0]["source_date"], "2026-11-18")
        self.assertEqual(slots[0]["meal_slot"], "breakfast")
        items = slots[0]["items"]
        self.assertEqual([row["id"] for row in items], ["hist-log-001", "hist-log-002"])
        self.assertEqual([row["meal_slot"] for row in items], ["breakfast", "breakfast"])
        self.assertEqual([row["quantity"]["amount"] for row in items], ["100", "100"])
        self.assertEqual([row["quantity"]["unit"] for row in items], ["g", "g"])

        after_success = self.state()
        self.assertEqual(after_success["latest_slots_401_consumed"], 1)
        self.assertEqual(after_success["latest_slots_read_attempts"], 2)
        self.assertEqual(self.domain_state(after_success), domain_before,
                         "The successful read mutated the logged fixture baseline.")
        direct_after = type(self).server.state  # type: ignore[attr-defined]
        self.assertEqual(direct_after.enabled_slots, [
            "breakfast", "lunch", "dinner", "snack", "late_night_snack",
        ], "The successful read changed the slot preferences.")
        self.assertEqual(direct_after.goal, direct.goal,
                         "The successful read changed the effective goal.")
        self.assertEqual([row["id"] for row in direct_after.logs],
                         [f"hist-log-{index:03d}" for index in range(1, 9)])

    def test_latest_slots_read_401_is_atomic_under_concurrent_reads(self) -> None:
        self.request(
            "POST", "/__qa/reset", {"today": "2026-11-19", "latest_slots_401_once": True}
        )
        self.login()
        outcomes: list[int] = []

        def worker() -> None:
            outcomes.append(self.request("GET", "/api/logs/latest-slots")[0])

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(len(outcomes), 4)
        self.assertEqual(outcomes.count(401), 1, "The one-shot 401 was not atomic.")
        self.assertEqual(outcomes.count(200), 3)
        state = self.state()
        self.assertEqual(state["latest_slots_401_consumed"], 1)
        self.assertEqual(state["latest_slots_read_attempts"], 4)

    def test_latest_slots_read_401_reset_clears_arm_and_counters(self) -> None:
        self.request(
            "POST", "/__qa/reset", {"today": "2026-11-19", "latest_slots_401_once": True}
        )
        self.login()
        consumed = self.request("GET", "/api/logs/latest-slots")
        self.assertEqual(consumed[0], 401)
        armed = self.state()
        self.assertFalse(armed["latest_slots_401_armed"])
        self.assertEqual(armed["latest_slots_401_consumed"], 1)

        self.request("POST", "/__qa/reset", {"today": "2026-11-19"})
        self.login()
        cleared = self.state()
        for key in self.LATEST_DIAGNOSTIC_KEYS:
            self.assertNotIn(key, cleared, "Reset did not clear the opt-in diagnostics.")

        status, _, _ = self.request("GET", "/api/logs/latest-slots")
        self.assertEqual(status, 200)
        self.assertEqual(self.canonical_state(self.state()), self.canonical_state(cleared),
                         "A read after reset changed the canonical fixture state.")


if __name__ == "__main__":
    unittest.main(verbosity=2)
