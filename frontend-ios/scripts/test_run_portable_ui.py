#!/usr/bin/env python3
"""Pure contract tests for the portable UI acceptance driver."""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

import run_portable_ui as driver


class DestinationContractTests(unittest.TestCase):
    def test_exact_approved_destinations(self) -> None:
        self.assertEqual(
            driver.acceptance_platform(driver.MAC_DESTINATION), "macos"
        )
        self.assertEqual(
            driver.acceptance_platform(driver.IPAD_DESTINATION), "ios"
        )

    def test_rejects_any_other_destination_or_substitute(self) -> None:
        rejected = [
            "platform=macOS",
            "platform=macOS,arch=x86_64",
            "platform=iOS Simulator,name=iPad Air 11-inch (M4)",
            "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000",
            "platform=iOS Simulator,name=iPhone 17 Pro Max",
            "platform=iOS,id=00000000-0000-0000-0000-000000000000",
            "",
        ]
        for destination in rejected:
            with self.subTest(destination=destination):
                with self.assertRaises(driver.DriverError):
                    driver.acceptance_platform(destination)

    def assert_parser_rejects(self, argv: list[str]) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                driver.parse_args(argv)

    def test_parser_rejects_arbitrary_suite_or_expected_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = [
                "--destination",
                driver.MAC_DESTINATION,
                "--derived-data",
                str(Path(temporary) / "derived"),
                "--result-bundle",
                str(Path(temporary) / "result.xcresult"),
            ]
            self.assert_parser_rejects(
                base + ["--only-testing", "CalCoUITests/Other"]
            )
            self.assert_parser_rejects(base + ["--expected-tests", "1"])
            self.assert_parser_rejects(
                [
                    "--destination",
                    "platform=iOS Simulator,name=iPad Air 11-inch (M4)",
                    "--derived-data",
                    str(Path(temporary) / "derived"),
                    "--result-bundle",
                    str(Path(temporary) / "result.xcresult"),
                ]
            )

    def test_parser_rejects_existing_result_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = Path(temporary) / "existing.xcresult"
            result.mkdir()
            self.assert_parser_rejects(
                [
                    "--destination",
                    driver.MAC_DESTINATION,
                    "--derived-data",
                    str(Path(temporary) / "derived"),
                    "--result-bundle",
                    str(result),
                ]
            )

    def test_expected_count_and_suite_are_pinned(self) -> None:
        self.assertEqual(driver.EXPECTED_TEST_COUNT, 7)
        self.assertEqual(
            driver.PORTABLE_ONLY_TESTING,
            "CalCoUITests/PortableJourneyUITests",
        )


class XctestrunContractTests(unittest.TestCase):
    def test_runner_environment_is_injected_only_for_ui_runner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.xctestrun"
            destination = root / "run.xctestrun"
            with source.open("wb") as handle:
                plistlib.dump(
                    {
                        "CalCoUITests": {
                            "EnvironmentVariables": {"EXISTING": "yes"},
                            "UITargetAppEnvironmentVariables": {"APP_ONLY": "yes"},
                        },
                        "CalCoTests": {"EnvironmentVariables": {}},
                    },
                    handle,
                    fmt=plistlib.FMT_BINARY,
                )
            driver.inject_runner_environment(
                source, destination, "http://127.0.0.1:45678"
            )
            with destination.open("rb") as handle:
                data = plistlib.load(handle)
            self.assertEqual(
                data["CalCoUITests"]["EnvironmentVariables"][
                    "CALCO_PORTABLE_UI_BASE_URL"
                ],
                "http://127.0.0.1:45678",
            )
            self.assertEqual(
                data["CalCoUITests"]["EnvironmentVariables"]["EXISTING"], "yes"
            )
            self.assertNotIn(
                "CALCO_PORTABLE_UI_BASE_URL",
                data["CalCoUITests"]["UITargetAppEnvironmentVariables"],
            )
            self.assertNotIn(
                "CALCO_PORTABLE_UI_BASE_URL",
                data["CalCoTests"]["EnvironmentVariables"],
            )
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

    def test_shell_environment_does_not_forward_fixture_url(self) -> None:
        env = driver.apple_env("/Applications/Xcode.app/Contents/Developer")
        self.assertNotIn("CALCO_PORTABLE_UI_BASE_URL", env)
        self.assertEqual(env["NO_PROXY"], "127.0.0.1,localhost,::1")
        self.assertEqual(env["no_proxy"], "127.0.0.1,localhost,::1")
        self.assertIsNotNone(driver.loopback_opener())

    def test_prepare_private_xctestrun_copies_products_and_injects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            products = root / "Build" / "Products"
            products.mkdir(parents=True)
            (products / "Test").mkdir()
            source = products / "CalCo-E2E_macosx26.5-arm64.xctestrun"
            with source.open("wb") as handle:
                plistlib.dump(
                    {"CalCoUITests": {"EnvironmentVariables": {}}},
                    handle,
                    fmt=plistlib.FMT_BINARY,
                )
            private_run = root / "private-run"
            private_run.mkdir()
            os.chmod(private_run, 0o700)
            result = driver.prepare_private_xctestrun(
                products,
                "macos",
                "http://127.0.0.1:45679",
                private_run,
            )
            self.assertEqual(result, private_run / "run.xctestrun")
            with result.open("rb") as handle:
                data = plistlib.load(handle)
            self.assertEqual(
                data["CalCoUITests"]["EnvironmentVariables"][
                    "CALCO_PORTABLE_UI_BASE_URL"
                ],
                "http://127.0.0.1:45679",
            )
            self.assertTrue((private_run / "Test").is_symlink())

    def test_health_contract_rejects_marker_profile_or_identity_drift(
        self,
    ) -> None:
        valid = {
            "fixture": driver.FIXTURE_MARKER,
            "profile_id": driver.FIXTURE_PROFILE_ID,
            "identity_id": "11111111-1111-4111-8111-111111111111",
        }
        self.assertEqual(driver.validate_fixture_health(valid), valid)
        mutations = [
            ("fixture", "wrong"),
            ("profile_id", "00000000-0000-0000-0000-000000000000"),
            ("identity_id", driver.FIXTURE_PROFILE_ID),
            ("identity_id", "not-a-uuid"),
        ]
        for key, value in mutations:
            payload = dict(valid)
            payload[key] = value
            with self.subTest(key=key, value=value):
                with self.assertRaises(driver.DriverError):
                    driver.validate_fixture_health(payload)

    def test_count_contract_rejects_partial_skip_or_expected_failure(self) -> None:
        valid = {
            "totalTestCount": 7,
            "passedTests": 7,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }
        self.assertEqual(driver.validate_counts(valid, 7)["total"], 7)
        rejected = [
            {**valid, "totalTestCount": 6, "passedTests": 6},
            {**valid, "skippedTests": 1, "passedTests": 6},
            {**valid, "failedTests": 1, "passedTests": 6},
            {**valid, "expectedFailures": 1},
        ]
        for summary in rejected:
            with self.subTest(summary=summary):
                with self.assertRaises(driver.DriverError):
                    driver.validate_counts(summary, 7)


class PortableSwiftSourceContractTests(unittest.TestCase):
    def test_seven_tests_and_no_skip_path(self) -> None:
        source = (
            Path(__file__).resolve().parent.parent
            / "UITests"
            / "PortableJourneyUITests.swift"
        )
        text = source.read_text(encoding="utf-8")
        self.assertEqual(text.count("func test"), 7)
        self.assertNotIn("XCTSkip", text)
        self.assertNotIn("throw XCTSkip", text)
        self.assertNotIn("X-CalCo-Account-ID", text)


if __name__ == "__main__":
    unittest.main()
