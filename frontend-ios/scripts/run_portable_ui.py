#!/usr/bin/env python3
"""Run the portable UI acceptance suite against one approved destination.

Acceptance is intentionally not configurable: the destination, test class, and
expected count are pinned. There is no non-acceptance mode.

The driver owns fixture lifetime:

1. build-for-testing for the approved destination;
2. copy the generated xctestrun into a private 0700 run directory and inject
   ``CALCO_PORTABLE_UI_BASE_URL`` into the ``CalCoUITests`` runner environment;
3. start the bounded fixture wrapper and verify its live ``/__qa/health``
   contract;
4. run ``test-without-building`` with ``-xctestrun`` under a hard timeout;
5. terminate and reap the fixture in ``finally``;
6. require executed == 7, passed == 7, failed == 0, skipped == 0.

No files are deleted. Derived data, result bundles, logs, and the private
xctestrun directory are retained for provenance.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
PROJECT = REPO_ROOT / "frontend-ios" / "CalCo.xcodeproj"
FIXTURE_WRAPPER = (
    REPO_ROOT / "frontend-ios" / "UITests" / "PortableQAMockServer.py"
)
SCHEME = "CalCo-E2E"
CONFIGURATION = "Test"
PORTABLE_ONLY_TESTING = "CalCoUITests/PortableJourneyUITests"
EXPECTED_TEST_COUNT = 7
MAC_DESTINATION = "platform=macOS,arch=arm64"
IPAD_DESTINATION = (
    "platform=iOS Simulator,id=C9CE77F1-89E8-4DF5-B101-871105BCED9B"
)
FIXTURE_MARKER = "native-completion-qa"
FIXTURE_PROFILE_ID = "22222222-2222-4222-8222-222222222222"
ACCOUNT_HEADER = "X-CalCo-Account-ID"
APPLE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
SIGNING_NAME_MARKERS = (
    "CODE_SIGN",
    "PROVISIONING_",
    "KEYCHAIN",
    "DEVELOPMENT_TEAM",
)


class DriverError(Exception):
    """A usage, fixture, build, or result-verification failure."""


def acceptance_platform(destination: str) -> str:
    """Return the approved platform name or reject the destination."""
    if destination == MAC_DESTINATION:
        return "macos"
    if destination == IPAD_DESTINATION:
        return "ios"
    raise DriverError(
        "destination is not approved for portable acceptance; use exactly "
        f"{MAC_DESTINATION!r} or {IPAD_DESTINATION!r}"
    )


def apple_env(developer_dir: str) -> dict[str, str]:
    """Cleaned Apple-tool environment; never prints signing values."""
    env = {
        "HOME": os.environ.get("HOME", ""),
        "TMPDIR": os.environ.get("TMPDIR", tempfile.gettempdir()),
        "USER": os.environ.get("USER", ""),
        "LOGNAME": os.environ.get("LOGNAME", os.environ.get("USER", "")),
        "SHELL": "/bin/sh",
        "TERM": "dumb",
        "PATH": APPLE_PATH,
        "DEVELOPER_DIR": developer_dir,
        "NO_PROXY": "127.0.0.1,localhost,::1",
        "no_proxy": "127.0.0.1,localhost,::1",
    }
    for name, value in os.environ.items():
        if any(marker in name for marker in SIGNING_NAME_MARKERS):
            env[name] = value
    return env


def validate_fixture_health(payload: object) -> dict:
    """Validate the live QA fixture identity/binding contract."""
    if not isinstance(payload, dict):
        raise DriverError("fixture health was not a JSON object")
    if payload.get("fixture") != FIXTURE_MARKER:
        raise DriverError(
            f"fixture marker is not {FIXTURE_MARKER!r}: "
            f"{payload.get('fixture')!r}"
        )
    if payload.get("profile_id") != FIXTURE_PROFILE_ID:
        raise DriverError("fixture profile UUID does not match the contract")
    if payload.get("account_header") != ACCOUNT_HEADER:
        raise DriverError("fixture account-binding header does not match")
    identity = payload.get("identity_id")
    if not isinstance(identity, str):
        raise DriverError("fixture has no identity UUID")
    try:
        identity_uuid = uuid.UUID(identity)
        profile_uuid = uuid.UUID(str(payload.get("profile_id")))
    except (ValueError, TypeError) as exc:
        raise DriverError(f"fixture UUIDs are malformed: {exc}") from exc
    if identity_uuid == profile_uuid:
        raise DriverError("fixture identity and profile UUIDs are not distinct")
    return payload


def loopback_opener() -> urllib.request.OpenerDirector:
    """Never route a loopback fixture through an HTTP proxy."""
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_fixture_health(base_url: str) -> dict:
    url = base_url.rstrip("/") + "/__qa/health"
    try:
        with loopback_opener().open(url, timeout=10) as response:
            if response.status != 200:
                raise DriverError(f"fixture health returned {response.status}")
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
        raise DriverError(f"fixture health request failed: {exc}") from exc
    return validate_fixture_health(payload)


def wait_for_ready(
    path: Path,
    process: subprocess.Popen,
    timeout: float,
) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise DriverError(
                f"portable fixture exited before ready (status {process.returncode})"
            )
        if path.exists():
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise DriverError(f"invalid fixture ready marker: {exc}") from exc
            if not isinstance(payload, dict):
                raise DriverError("fixture ready marker was not an object")
            if payload.get("fixture") != FIXTURE_MARKER:
                raise DriverError(
                    "fixture ready marker did not identify native-completion-qa"
                )
            if payload.get("profile_id") != FIXTURE_PROFILE_ID:
                raise DriverError("fixture ready marker profile UUID is wrong")
            if payload.get("account_header") != ACCOUNT_HEADER:
                raise DriverError("fixture ready marker account header is wrong")
            identity = payload.get("identity_id")
            try:
                if uuid.UUID(str(identity)) == uuid.UUID(FIXTURE_PROFILE_ID):
                    raise DriverError(
                        "fixture ready marker identity equals profile UUID"
                    )
            except (ValueError, TypeError) as exc:
                raise DriverError(
                    f"fixture ready marker identity UUID is malformed: {exc}"
                ) from exc
            if not isinstance(payload.get("port"), int) or not payload["port"]:
                raise DriverError("fixture ready marker has no usable port")
            return payload
        time.sleep(0.1)
    raise DriverError("timed out waiting for the portable fixture ready marker")


def stop_process(process: subprocess.Popen, label: str) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(process.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        process.terminate()
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            process.kill()
        process.wait(timeout=8)
    print(f"{label} stopped (status {process.returncode})", flush=True)


def run_xcodebuild(
    command: list[str],
    env: dict[str, str],
    timeout: float,
    log_path: Path,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_process(process, "xcodebuild")
            raise DriverError(f"xcodebuild exceeded the {timeout:g}s timeout")


def inject_runner_environment(
    source: Path,
    destination: Path,
    base_url: str,
) -> None:
    """Inject the nonsecret fixture URL only into the UI runner environment."""
    with source.open("rb") as handle:
        data = plistlib.load(handle)
    if not isinstance(data, dict):
        raise DriverError("xctestrun root is not a plist dictionary")
    runner = data.get("CalCoUITests")
    if not isinstance(runner, dict):
        raise DriverError("xctestrun has no CalCoUITests target")
    environment = runner.get("EnvironmentVariables")
    if not isinstance(environment, dict):
        environment = {}
        runner["EnvironmentVariables"] = environment
    environment["CALCO_PORTABLE_UI_BASE_URL"] = base_url
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
    os.chmod(destination, 0o600)
    with destination.open("rb") as handle:
        check = plistlib.load(handle)
    injected = check.get("CalCoUITests", {}).get(
        "EnvironmentVariables", {}
    ).get("CALCO_PORTABLE_UI_BASE_URL")
    if injected != base_url:
        raise DriverError("private xctestrun did not retain the fixture URL")
    if "CALCO_PORTABLE_UI_BASE_URL" in check.get("CalCoUITests", {}).get(
        "UITargetAppEnvironmentVariables", {}
    ):
        raise DriverError("fixture URL leaked into the app target environment")


def prepare_private_xctestrun(
    build_products: Path,
    platform: str,
    base_url: str,
    private_run: Path | None = None,
) -> Path:
    if platform == "macos":
        pattern = "CalCo-E2E_macosx*.xctestrun"
    elif platform == "ios":
        pattern = "CalCo-E2E_iphonesimulator*.xctestrun"
    else:
        raise DriverError(f"unsupported acceptance platform: {platform}")
    matches = sorted(glob.glob(str(build_products / pattern)))
    if len(matches) != 1:
        raise DriverError(
            f"expected exactly one {pattern} in {build_products}; "
            f"found {len(matches)}"
        )
    source = Path(matches[0])

    if private_run is None:
        private_run = Path(
            tempfile.mkdtemp(
                prefix="calco-portable-run-", dir=tempfile.gettempdir()
            )
        )
        os.chmod(private_run, 0o700)
    destination = private_run / "run.xctestrun"
    shutil.copy2(source, destination)
    os.chmod(destination, 0o600)
    for product in build_products.iterdir():
        if product.is_dir() and product.name.startswith("Test"):
            link = private_run / product.name
            if not link.exists():
                os.symlink(product, link, target_is_directory=True)
    inject_runner_environment(source, destination, base_url)
    return destination


def find_metric(value: object, names: tuple[str, ...]) -> int | None:
    if isinstance(value, dict):
        for name in names:
            candidate = value.get(name)
            if isinstance(candidate, int):
                return candidate
        for child in value.values():
            found = find_metric(child, names)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_metric(child, names)
            if found is not None:
                return found
    return None


def validate_counts(summary: object, expected: int) -> dict[str, int]:
    if not isinstance(summary, dict):
        raise DriverError("result summary was not a JSON object")
    total = find_metric(summary, ("totalTestCount", "testCount", "testsCount"))
    passed = find_metric(summary, ("passedTests", "passedTestCount"))
    failed = find_metric(summary, ("failedTests", "failedTestCount"))
    skipped = find_metric(summary, ("skippedTests", "skippedTestCount"))
    expected_failures = find_metric(summary, ("expectedFailures",))
    if total is None:
        raise DriverError("result summary did not expose a test count")
    if passed is None or failed is None or skipped is None:
        raise DriverError("result summary did not expose pass/fail/skip counts")
    if total != expected:
        raise DriverError(
            f"executed {total} tests, expected {expected}; "
            "refusing to treat a partial suite as device acceptance"
        )
    if passed != expected or failed != 0 or skipped != 0:
        raise DriverError(
            f"expected {expected} passed, 0 failed, 0 skipped; "
            f"observed {passed} passed, {failed} failed, {skipped} skipped"
        )
    if expected_failures:
        raise DriverError(
            f"expected failures are not accepted ({expected_failures} observed)"
        )
    return {
        "total": total,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "expectedFailures": expected_failures or 0,
    }


def verify_result(result_path: Path, developer_dir: str) -> dict[str, int]:
    command = [
        "/usr/bin/xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(result_path),
        "--format",
        "json",
    ]
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        env={
            "HOME": os.environ.get("HOME", ""),
            "PATH": APPLE_PATH,
            "DEVELOPER_DIR": developer_dir,
        },
        text=True,
        capture_output=True,
        timeout=120,
    )
    if completed.returncode != 0:
        raise DriverError(
            "could not read result bundle: "
            + (completed.stderr.strip() or completed.stdout.strip())
        )
    try:
        summary = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise DriverError(f"result summary was not JSON: {exc}") from exc
    return validate_counts(summary, EXPECTED_TEST_COUNT)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--build-timeout", type=float, default=900.0)
    parser.add_argument("--fixture-max-seconds", type=float, default=3600.0)
    parser.add_argument("--fixture-startup-timeout", type=float, default=20.0)
    parser.add_argument(
        "--developer-dir",
        default=os.environ.get("DEVELOPER_DIR", DEFAULT_DEVELOPER_DIR),
    )
    parser.add_argument("--verbose-fixture", action="store_true")
    args = parser.parse_args(argv)

    try:
        args.platform = acceptance_platform(args.destination)
    except DriverError as exc:
        parser.error(str(exc))
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.build_timeout <= 0:
        parser.error("--build-timeout must be positive")
    if args.fixture_max_seconds <= 0:
        parser.error("--fixture-max-seconds must be positive")
    if Path(args.result_bundle).exists():
        parser.error(
            f"result bundle already exists: {args.result_bundle}; "
            "choose a new path (no deletion is performed)"
        )
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    developer_dir = args.developer_dir
    xcodebuild = str(Path(developer_dir) / "usr" / "bin" / "xcodebuild")
    if not Path(xcodebuild).is_file():
        raise DriverError(f"xcodebuild not found at {xcodebuild}")

    derived_data = Path(args.derived_data)
    result_bundle = Path(args.result_bundle)
    result_bundle.parent.mkdir(parents=True, exist_ok=True)
    build_log = result_bundle.with_suffix(".build.log")
    test_log = result_bundle.with_suffix(".xcodebuild.log")
    env = apple_env(developer_dir)
    fixture_process: subprocess.Popen | None = None
    fixture_log_handle = None
    private_run: Path | None = None
    try:
        build_command = [
            xcodebuild,
            "-project",
            str(PROJECT),
            "-scheme",
            SCHEME,
            "-configuration",
            CONFIGURATION,
            "-destination",
            args.destination,
            "-derivedDataPath",
            str(derived_data),
            "build-for-testing",
        ]
        print("building: " + " ".join(build_command), flush=True)
        build_status = run_xcodebuild(
            build_command, env, args.build_timeout, build_log
        )
        print(f"build status {build_status}; log {build_log}", flush=True)
        if build_status != 0:
            raise DriverError(f"build-for-testing failed with status {build_status}")

        build_products = derived_data / "Build" / "Products"
        private_run = Path(
            tempfile.mkdtemp(
                prefix="calco-portable-run-", dir=tempfile.gettempdir()
            )
        )
        os.chmod(private_run, 0o700)
        ready_path = private_run / "fixture-ready.json"
        fixture_log = private_run / "fixture.log"
        fixture_log_handle = fixture_log.open("w", encoding="utf-8")

        fixture_command = [
            sys.executable,
            str(FIXTURE_WRAPPER),
            "--port",
            "0",
            "--ready-file",
            str(ready_path),
            "--max-seconds",
            str(args.fixture_max_seconds),
        ]
        if args.verbose_fixture:
            fixture_command.append("--verbose")
        fixture_process = subprocess.Popen(
            fixture_command,
            stdout=fixture_log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        ready = wait_for_ready(
            ready_path, fixture_process, args.fixture_startup_timeout
        )
        base_url = ready["base_url"]
        health = fetch_fixture_health(base_url)
        print(
            f"fixture verified at {base_url} "
            f"(profile {health['profile_id']}, identity distinct)",
            flush=True,
        )

        xctestrun = prepare_private_xctestrun(
            build_products, args.platform, base_url, private_run
        )
        print(f"private xctestrun: {xctestrun}", flush=True)
        command = [
            xcodebuild,
            "-xctestrun",
            str(xctestrun),
            "-destination",
            args.destination,
            "-only-testing:" + PORTABLE_ONLY_TESTING,
            "-resultBundlePath",
            str(result_bundle),
            "test-without-building",
        ]
        print("running: " + " ".join(command), flush=True)
        status = run_xcodebuild(command, env, args.timeout, test_log)
        print(f"xcodebuild status {status}; log {test_log}", flush=True)
        if status != 0:
            raise DriverError(f"portable UI tests failed with status {status}")

        summary = verify_result(result_bundle, developer_dir)
        print(
            "verified: "
            f"{summary['total']} executed, {summary['passed']} passed, "
            f"{summary['failed']} failed, {summary['skipped']} skipped",
            flush=True,
        )
        return 0
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr, flush=True)
        return 1
    finally:
        if fixture_process is not None:
            stop_process(fixture_process, "portable fixture")
        if fixture_log_handle is not None:
            fixture_log_handle.close()
        if private_run is not None:
            print(f"private run directory: {private_run}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
