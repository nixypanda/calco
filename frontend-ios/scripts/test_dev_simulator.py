"""Focused tests for device resolution and error paths.

These never boot, install, launch, or erase a simulator: they feed a saved
simctl JSON payload to the resolver and exercise dry-run command planning.
Run with: python3 -m unittest discover -s frontend-ios/scripts -p 'test_*.py'
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from unittest import mock

import dev_simulator as dv

IOS_RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
WATCH_RUNTIME = "com.apple.CoreSimulator.SimRuntime.watchOS-26-5"


def device(name: str, udid: str, state: str = "Shutdown", runtime: str = IOS_RUNTIME) -> dict:
    return {"name": name, "udid": udid, "state": state, "runtime": runtime}


def payload(devices: list[dict]) -> dict:
    return {"devices": {IOS_RUNTIME: devices, WATCH_RUNTIME: [
        device("iPhone 13 mini", "WATCH-UDID", runtime=WATCH_RUNTIME),
    ]}}


class LabelValidationTests(unittest.TestCase):
    def test_exact_names_no_fallback(self):
        self.assertEqual(dv.validate_target_and_label("ios", "mini"), "iPhone 13 mini")
        self.assertEqual(dv.validate_target_and_label("ios", "18-pro"), "iPhone 18 Pro")
        self.assertNotEqual(
            dv.validate_target_and_label("ios", "18-pro"), "iPhone 17 Pro"
        )
        self.assertEqual(dv.validate_target_and_label("ios", "duo"), "iPhone Duo")
        self.assertEqual(
            dv.validate_target_and_label("ipados", "mini"), "iPad mini (A17 Pro)"
        )
        self.assertEqual(
            dv.validate_target_and_label("ipados", "air"), "iPad Air 11-inch (M4)"
        )

    def test_unknown_labels_are_rejected_with_usage(self):
        for target, label in (("ios", "bogus"), ("ipados", "17-pro"), ("ios", "")):
            with self.subTest(target=target, label=label):
                with self.assertRaises(dv.UsageError) as ctx:
                    dv.validate_target_and_label(target, label)
                message = str(ctx.exception)
                self.assertIn("Usage:", message)
                self.assertIn("labels:", message)

    def test_macos_takes_no_label(self):
        self.assertIsNone(dv.validate_target_and_label("macos", None))
        with self.assertRaises(dv.UsageError) as ctx:
            dv.validate_target_and_label("macos", "mini")
        self.assertIn("takes no device label", str(ctx.exception))


class DryRunEnvParsingTests(unittest.TestCase):
    """Only explicit true values enable dry-run; false/0/unset mean execute.

    These exercise argument parsing only — no main()/run_plan() call, so the
    launcher is never executed even when the flag resolves to False.
    """

    def test_explicit_true_values_enable_dry_run(self):
        for value in ("1", "true", "TRUE", "Yes", "yes", " on "):
            with self.subTest(value=value):
                with mock.patch.dict(os.environ, {dv.DRY_RUN_ENV: value}):
                    self.assertTrue(dv.parse_args(["ios", "mini"]).dry_run)

    def test_false_empty_and_unset_values_mean_execute(self):
        for value in ("0", "false", "FALSE", "no", "off", "", " 0 "):
            with self.subTest(value=value):
                with mock.patch.dict(os.environ, {dv.DRY_RUN_ENV: value}):
                    self.assertFalse(dv.parse_args(["ios", "mini"]).dry_run)
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(dv.parse_args(["ios", "mini"]).dry_run)

    def test_cli_flag_overrides_false_env(self):
        with mock.patch.dict(os.environ, {dv.DRY_RUN_ENV: "0"}):
            self.assertTrue(dv.parse_args(["--dry-run", "ios", "mini"]).dry_run)


class DeviceResolutionTests(unittest.TestCase):
    def test_ignores_non_ios_runtimes(self):
        # Only a watchOS runtime has that name; it must not be a candidate.
        data = {"devices": {WATCH_RUNTIME: [
            device("iPhone 13 mini", "WATCH-UDID", runtime=WATCH_RUNTIME),
        ]}}
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "mini", data)
        self.assertIn("No installed simulator", str(ctx.exception))

    def test_prefers_unique_booted_match(self):
        data = payload([
            device("iPad mini (A17 Pro)", "AAA-SHUTDOWN"),
            device("iPad mini (A17 Pro)", "BBB-BOOTED", state="Booted"),
        ])
        found, note = dv.resolve_device("ipados", "mini", data)
        self.assertEqual(found["udid"], "BBB-BOOTED")
        self.assertEqual(note, "")

    def test_duplicate_shutdown_names_are_deterministic(self):
        a = device("iPad mini (A17 Pro)", "AAA-LOWER")
        b = device("iPad mini (A17 Pro)", "ZZZ-HIGHER")
        first, note = dv.resolve_device("ipados", "mini", payload([a, b]))
        second, _ = dv.resolve_device("ipados", "mini", payload([b, a]))
        self.assertEqual(first["udid"], "AAA-LOWER")
        self.assertEqual(second["udid"], first["udid"])
        self.assertIn("AAA-LOWER", note)
        self.assertIn("Pin another", note)

    def test_multiple_booted_matches_require_override(self):
        data = payload([
            device("iPhone 13 mini", "BOOT-1", state="Booted"),
            device("iPhone 13 mini", "BOOT-2", state="Booted"),
        ])
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "mini", data)
        self.assertIn(dv.UDID_ENV, str(ctx.exception))

    def test_udid_override_pins_exact_device(self):
        data = payload([
            device("iPhone 13 mini", "BOOTED", state="Booted"),
            device("iPhone 13 mini", "PINNED"),
        ])
        found, note = dv.resolve_device("ios", "mini", data, udid_override="PINNED")
        self.assertEqual(found["udid"], "PINNED")
        self.assertIn(dv.UDID_ENV, note)

    def test_bad_udid_override_is_an_error(self):
        data = payload([device("iPhone 13 mini", "REAL")])
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "mini", data, udid_override="NOPE")
        self.assertIn("NOPE", str(ctx.exception))

    def test_missing_device_errors_are_actionable(self):
        data = payload([device("iPhone 13 mini", "REAL")])
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "18-pro", data)
        message = str(ctx.exception)
        self.assertIn("iPhone 18 Pro", message)
        self.assertIn("No fallback", message)
        self.assertIn(dv.DEVELOPER_DIR_ENV, message)
        self.assertIn("iPhone 13 mini", message)

        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "duo", data)
        message = str(ctx.exception)
        self.assertIn("iPhone Duo", message)
        self.assertIn(dv.DEVELOPER_DIR_ENV, message)

    def test_unavailable_list_filters_by_requested_platform(self):
        mixed = payload([
            device("iPhone 13 mini", "IPH-MINI"),
            device("iPhone 18 Pro", "IPH-PRO"),
            device("iPad mini (A17 Pro)", "IPAD-MINI"),
        ])
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "duo", mixed)
        message = str(ctx.exception)
        self.assertIn("iPhone 13 mini", message)
        self.assertIn("iPhone 18 Pro", message)
        self.assertNotIn("iPad mini", message)

        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ipados", "air", mixed)
        message = str(ctx.exception)
        self.assertIn("iPad mini (A17 Pro)", message)
        self.assertNotIn("iPhone 13 mini", message)
        self.assertNotIn("iPhone 18 Pro", message)

    def test_bad_udid_override_list_is_platform_filtered(self):
        mixed = payload([
            device("iPhone 13 mini", "REAL"),
            device("iPad mini (A17 Pro)", "IPAD"),
        ])
        with self.assertRaises(dv.UsageError) as ctx:
            dv.resolve_device("ios", "mini", mixed, udid_override="NOPE")
        message = str(ctx.exception)
        self.assertIn("iPhone 13 mini", message)
        self.assertNotIn("iPad mini", message)


class EnvironmentIsolationTests(unittest.TestCase):
    def test_apple_env_drops_nix_and_sdk_flags(self):
        hostile = {
            "HOME": "/custom/home",
            "TMPDIR": "/custom/tmp",
            "USER": "tester",
            "SDKROOT": "/nix/store/SDK",
            "NIX_LDFLAGS": "-L/nix/store/lib",
            "NIX_CFLAGS_COMPILE": "-isystem /nix/store/include",
            "LD_DYLD_PATH": "/usr/lib/dyld",
            "CC": "nix-clang",
            "DEVELOPMENT_TEAM": "TEAM123",
            "CALCO_XCODE_DEVELOPER_DIR": "/ignored/by/apple_env",
            "PATH": "/nix/store/clang/bin",
        }
        with mock.patch.dict(os.environ, hostile, clear=False):
            env = dv.apple_env("/wanted/Developer")
        self.assertEqual(env["DEVELOPER_DIR"], "/wanted/Developer")
        self.assertEqual(env["PATH"], dv.APPLE_PATH)
        self.assertEqual(env["HOME"], "/custom/home")
        self.assertEqual(env["TMPDIR"], "/custom/tmp")
        self.assertEqual(env["DEVELOPMENT_TEAM"], "TEAM123")
        for key in ("SDKROOT", "NIX_LDFLAGS", "NIX_CFLAGS_COMPILE", "LD_DYLD_PATH",
                    "CC", "CALCO_XCODE_DEVELOPER_DIR"):
            self.assertNotIn(key, env)

    def test_signing_env_keys_are_matched_by_name(self):
        signing = (
            "CODE_SIGN_IDENTITY",
            "CODE_SIGN_STYLE",
            "OTHER_CODE_SIGN_FLAGS",
            "DEVELOPMENT_TEAM",
            "PROVISIONING_PROFILE_SPECIFIER",
            "PROVISIONING_PROFILE",
            "KEYCHAIN_PATH",
        )
        for key in signing:
            with self.subTest(key=key):
                self.assertTrue(dv.is_signing_env_key(key))
        for key in ("SDKROOT", "NIX_LDFLAGS", "LD_LIBRARY_PATH",
                    "DYLD_INSERT_LIBRARIES", "PATH"):
            with self.subTest(key=key):
                self.assertFalse(dv.is_signing_env_key(key))

    def test_code_sign_style_and_flags_survive_but_nix_flags_do_not(self):
        signing = {
            "CODE_SIGN_IDENTITY": "Apple Development",
            "CODE_SIGN_STYLE": "Manual",
            "OTHER_CODE_SIGN_FLAGS": "--keychain /tmp/k",
            "DEVELOPMENT_TEAM": "TEAM123",
            "PROVISIONING_PROFILE_SPECIFIER": "A Profile",
            "KEYCHAIN_PATH": "/tmp/k",
        }
        hostile = {
            "SDKROOT": "/nix/store/SDK",
            "LD_DYLD_PATH": "/usr/lib/dyld",
            "LD_LIBRARY_PATH": "/nix/store/lib",
            "DYLD_INSERT_LIBRARIES": "/nix/store/lib/x.dylib",
        }
        with mock.patch.dict(os.environ, {**signing, **hostile}, clear=False):
            env = dv.apple_env("/D")
        for key, value in signing.items():
            with self.subTest(key=key):
                self.assertEqual(env[key], value)
        for key in hostile:
            with self.subTest(key=key):
                self.assertNotIn(key, env)


class PlanTests(unittest.TestCase):
    def test_booted_device_is_never_booted_or_shut_down(self):
        commands, _ = dv.simulator_plan(device("iPhone 13 mini", "BOOTED", "Booted"))
        flat = " ".join(" ".join(c) for c in commands)
        self.assertNotIn("simctl boot", flat)
        self.assertNotIn("shutdown", flat)
        self.assertNotIn("erase", flat)
        self.assertIn("simctl install BOOTED", flat)
        self.assertIn("simctl launch BOOTED dev.calco.CalCo", flat)
        self.assertIn("-CurrentDeviceUDID BOOTED", flat)

    def test_shutdown_target_is_booted_then_installed(self):
        commands, _ = dv.simulator_plan(device("iPad mini (A17 Pro)", "IPAD"))
        self.assertEqual(commands[1], ["/usr/bin/xcrun", "simctl", "boot", "IPAD"])

    def test_macos_plan_builds_and_opens(self):
        commands, app = dv.macos_plan()
        self.assertIn("-destination", commands[0])
        self.assertEqual(commands[0][commands[0].index("-destination") + 1],
                         "generic/platform=macOS")
        self.assertEqual(commands[-1], ["/usr/bin/open", app])

    def test_dry_run_executes_nothing(self):
        commands, _ = dv.simulator_plan(device("iPhone 13 mini", "BOOTED", "Booted"))
        out = io.StringIO()
        with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
            with contextlib.redirect_stdout(out):
                dv.run_plan(commands, "/D", dry_run=True)
        text = out.getvalue()
        self.assertIn("[dry-run] /usr/bin/xcodebuild", text)
        self.assertIn("[dry-run] /usr/bin/xcrun simctl install", text)
        self.assertNotIn("simctl boot", text)


class MainDryRunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.json_path = os.path.join(self.tmp.name, "devices.json")
        with open(self.json_path, "w", encoding="utf-8") as handle:
            json.dump(payload([
                device("iPhone 13 mini", "BOOTED", "Booted"),
                device("iPad mini (A17 Pro)", "IPAD-1"),
                device("iPad mini (A17 Pro)", "IPAD-2"),
            ]), handle)
        self.env_patch = mock.patch.dict(os.environ, {
            dv.DEVELOPER_DIR_ENV: self.tmp.name,
            dv.DRY_RUN_ENV: "1",
            dv.SIMCTL_JSON_ENV: self.json_path,
        })
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_dry_run_resolves_booted_mini_without_side_effects(self):
        out = io.StringIO()
        with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
            with contextlib.redirect_stdout(out):
                code = dv.main(["ios", "mini"])
        self.assertEqual(code, 0)
        text = out.getvalue()
        self.assertIn("iPhone 13 mini", text)
        self.assertIn("UDID BOOTED", text)
        self.assertIn("[dry-run] /usr/bin/xcrun simctl launch BOOTED", text)
        self.assertNotIn("simctl boot", text)

    def test_unavailable_target_exits_with_message(self):
        err = io.StringIO()
        with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
            with contextlib.redirect_stderr(err):
                with contextlib.redirect_stdout(io.StringIO()):
                    code = dv.main(["ios", "18-pro"])
        self.assertEqual(code, 2)
        self.assertIn("iPhone 18 Pro", err.getvalue())

    def test_unknown_label_exits_with_message(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with contextlib.redirect_stdout(io.StringIO()):
                code = dv.main(["ipados", "duo"])
        self.assertEqual(code, 2)
        self.assertIn("Unknown ipados label 'duo'", err.getvalue())

    def test_macos_dry_run(self):
        out = io.StringIO()
        with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
            with contextlib.redirect_stdout(out):
                code = dv.main(["macos"])
        self.assertEqual(code, 0)
        self.assertIn("[dry-run] /usr/bin/xcodebuild", out.getvalue())
        self.assertIn("[dry-run] /usr/bin/open", out.getvalue())

    def test_signing_secret_is_not_printed(self):
        secret = "SUPER-SECRET-CODE-SIGN-VALUE"
        with mock.patch.dict(os.environ, {"OTHER_CODE_SIGN_FLAGS": secret}):
            out = io.StringIO()
            with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
                with contextlib.redirect_stdout(out):
                    code = dv.main(["ios", "mini"])
        self.assertEqual(code, 0)
        self.assertNotIn(secret, out.getvalue())


class SimctlJsonInputTests(unittest.TestCase):
    """A bad saved simctl JSON path is a friendly usage error, not a traceback."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env_patch = mock.patch.dict(os.environ, {
            dv.DEVELOPER_DIR_ENV: self.tmp.name,
            dv.DRY_RUN_ENV: "1",
        })
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def run_main(self, json_path: str) -> tuple[int, str, str]:
        err, out = io.StringIO(), io.StringIO()
        with mock.patch.object(dv.subprocess, "run", side_effect=AssertionError("ran!")):
            with contextlib.redirect_stderr(err):
                with contextlib.redirect_stdout(out):
                    code = dv.main(["ios", "mini", "--simctl-json", json_path])
        return code, err.getvalue(), out.getvalue()

    def test_missing_json_path_is_a_friendly_error(self):
        missing = os.path.join(self.tmp.name, "does-not-exist.json")
        code, err, out = self.run_main(missing)
        self.assertEqual(code, 2)
        self.assertIn(dv.SIMCTL_JSON_ENV, err)
        self.assertIn("Could not read", err)
        self.assertNotIn("Traceback", err)
        self.assertNotIn("ran!", out)

    def test_malformed_json_is_a_friendly_error(self):
        bad = os.path.join(self.tmp.name, "bad.json")
        with open(bad, "w", encoding="utf-8") as handle:
            handle.write("{not valid json")
        code, err, out = self.run_main(bad)
        self.assertEqual(code, 2)
        self.assertIn(dv.SIMCTL_JSON_ENV, err)
        self.assertIn("Could not read", err)
        self.assertNotIn("Traceback", err)
        self.assertNotIn("ran!", out)


if __name__ == "__main__":
    unittest.main()
