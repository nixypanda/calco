#!/usr/bin/env python3
"""Focused contract tests for NativeCompletionQAMockServer.

Run directly:
  python3 frontend-ios/UITests/NativeCompletionQAMockServerTests.py
"""

from __future__ import annotations

import json
import threading
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
        account_id: str | None = None,
    ) -> tuple[int, dict, object]:
        data = None if body is None else json.dumps(body).encode()
        return self.request_raw(
            method,
            path,
            data,
            "application/json" if data is not None else None,
            account_id,
        )

    def request_raw(
        self,
        method: str,
        path: str,
        data: bytes | None,
        content_type: str | None,
        account_id: str | None,
    ) -> tuple[int, dict, object]:
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Accept", "application/json")
        if content_type is not None:
            request.add_header("Content-Type", content_type)
        if self.cookie:
            request.add_header("Cookie", self.cookie)
        if account_id is not None:
            request.add_header(mock.ACCOUNT_HEADER, account_id)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
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
            mock.FIXTURE_PROFILE_ID,
        )

    def test_session_identity_and_profile_are_distinct_valid_uuids(self) -> None:
        status, payload, _ = self.request("GET", "/api/auth/session")
        self.assertEqual(status, 200)
        identity = payload["identity"]["id"]
        profile = payload["profile"]["id"]
        self.assertNotEqual(identity, profile)
        uuid.UUID(identity)
        uuid.UUID(profile)
        self.assertEqual(profile, mock.FIXTURE_PROFILE_ID)

    def test_capability_exposes_binding_and_accepts_matching_profile(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/capabilities",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        capability = payload["log_creation_idempotency"]
        self.assertEqual(capability["request_account_binding"], "x-calco-account-id")
        self.assertEqual(capability["version"], 2)
        self.assertEqual(self.server.state.bound_request_count, 1)
        self.assertEqual(self.server.state.unbound_protected_request_count, 0)

    def test_protected_request_with_wrong_profile_is_session_account_changed(self) -> None:
        wrong = str(uuid.uuid4())
        status, payload, _ = self.request(
            "GET",
            "/api/goal",
            account_id=wrong,
        )
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "session_account_changed")

    def test_protected_request_with_malformed_header_is_rejected(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/goal",
            account_id="not-a-uuid",
        )
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "invalid_account_header")

    def test_legacy_missing_header_is_still_allowed(self) -> None:
        status, _, _ = self.request("GET", "/api/goal")
        self.assertEqual(status, 200)

    def test_nutrient_catalog_has_all_four_required_definitions(self) -> None:
        status, payload, _ = self.request(
            "GET",
            "/api/nutrients",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
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
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 201)
        food_id = payload["id"]
        status, detail, _ = self.request(
            "GET",
            f"/api/foods/{food_id}",
            account_id=mock.FIXTURE_PROFILE_ID,
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
            account_id=mock.FIXTURE_PROFILE_ID,
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
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        self.assertFalse(payload["enabled"])

        reset = self.request(
            "POST",
            "/__qa/reset",
            {"today": "2026-11-19", "assistant_enabled": True},
        )
        self.assertEqual(reset[0], 200)
        login = self.request(
            "POST",
            "/api/auth/login",
            {"username": mock.FIXTURE_USERNAME, "password": mock.FIXTURE_PASSWORD},
        )
        self.assertEqual(login[0], 200)
        self.cookie = login[2].headers["Set-Cookie"].split(";", 1)[0]
        status, payload, _ = self.request(
            "GET",
            "/api/ai/food-assistant/status",
            account_id=mock.FIXTURE_PROFILE_ID,
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

    def test_meal_crud_and_missing_components_are_faithful(self) -> None:
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
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 201)
        meal_id = meal["id"]
        self.assertEqual(meal["name"], "Contract Meal")
        self.assertFalse(meal["has_missing_components"])
        status, detail, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        self.assertEqual(detail["notes"], "contract notes")
        status, preview, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}/nutrients?amount=100&unit=g",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        self.assertEqual(preview["meal_id"], meal_id)

        self.assertEqual(
            self.request("POST", "/__qa/remove-food", {"id": "qa-apple"})[0],
            200,
        )
        status, degraded, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        self.assertTrue(degraded["has_missing_components"])
        self.assertTrue(degraded["components"][0]["missing"])
        status, error, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}/nutrients?amount=100&unit=g",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 409)
        self.assertEqual(error["error"]["code"], "missing_components")

        status, error, _ = self.request(
            "POST",
            "/api/meals",
            body,
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 409)
        self.assertEqual(error["error"]["code"], "missing_components")

        repaired = dict(body)
        repaired["components"] = [
            {
                "item": {"type": "product", "id": "qa-pear"},
                "quantity": {"amount": "100", "unit": "g"},
            }
        ]
        status, updated, _ = self.request(
            "PUT",
            f"/api/meals/{meal_id}",
            repaired,
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        self.assertFalse(updated["has_missing_components"])
        status, preview, _ = self.request(
            "GET",
            f"/api/meals/{meal_id}/nutrients?amount=100&unit=g",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 200)
        status, _, _ = self.request(
            "DELETE",
            f"/api/meals/{meal_id}",
            account_id=mock.FIXTURE_PROFILE_ID,
        )
        self.assertEqual(status, 204)
        state = self.request("GET", "/__qa/state")[1]
        self.assertEqual(state["meal_create_count"], 1)
        self.assertEqual(state["meal_update_count"], 1)
        self.assertEqual(state["meal_delete_count"], 1)
        self.assertEqual(state["meal_count"], 1)

    def test_login_session_logout_ignore_account_binding_header(self) -> None:
        # Login is the bootstrap path and has no expected profile header yet.
        status, _, _ = self.request(
            "POST",
            "/api/auth/login",
            {"username": mock.FIXTURE_USERNAME, "password": mock.FIXTURE_PASSWORD},
            account_id="not-a-uuid",
        )
        self.assertEqual(status, 200)
        status, _, _ = self.request(
            "GET",
            "/api/auth/session",
            account_id="not-a-uuid",
        )
        self.assertEqual(status, 200)
        status, _, _ = self.request(
            "POST",
            "/api/auth/logout",
            account_id="not-a-uuid",
        )
        self.assertEqual(status, 204)


if __name__ == "__main__":
    unittest.main(verbosity=2)
