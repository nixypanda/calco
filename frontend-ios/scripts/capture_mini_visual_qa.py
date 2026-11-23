#!/usr/bin/env python3
"""Deterministic light/dark + default/AX5 visual QA capture for the exact mini.

Prerequisites: a fresh `build-for-testing` already produced the CalCo-E2E
xctestrun, and the loopback QA fixture is running. This script only drives the
simulator appearance and an already-built test bundle; it never edits source,
starts a backend, or signs in a real user. The original simulator appearance is
restored on every exit path.

Outputs (under --out):
  <appearance>/run.log            xcodebuild output for that appearance
  <appearance>/result.xcresult    test result bundle (must be green)
  <appearance>/attachments/       exported XCTest attachments (screenshots)
  <appearance>/screenshots/       readable PNG copies
  manifest.json                   appearance/text-size metadata per variant

Screenshots are evidence for parent pixel review, not automated product
approval: visualApproval is explicitly PENDING_PARENT_MANUAL_REVIEW.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DEVELOPER = "/Applications/Xcode.app/Contents/Developer"
XCODEBUILD = DEVELOPER + "/usr/bin/xcodebuild"
DEVICE = "90964888-D59F-41EC-8DA2-419C829F3A71"

DEFAULT_TESTS = [
    "CalCoUITests/NativeCompletionUITests/testMiniToolbarActionsStayReachableWhenCollapsed",
    "CalCoUITests/NativeCompletionUITests/testMiniDiarySummaryNutritionAndContextualSearchRetainTarget",
    "CalCoUITests/NativeCompletionUITests/testMiniMealCardHeaderTitleAndSubtotalStayVisible",
]

DEFAULT_APPEARANCES = ["light", "dark"]


class CaptureError(RuntimeError):
    pass


def clean_env() -> dict[str, str]:
    keys = ("HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "TERM", "PATH")
    env = {key: os.environ.get(key, "") for key in keys}
    env["SHELL"] = "/bin/sh"
    env["TERM"] = "dumb"
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    env["DEVELOPER_DIR"] = DEVELOPER
    return env


def run(argv: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        env=env or clean_env(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def simctl(*args: str) -> str:
    result = run(["xcrun", "simctl", *args])
    if result.returncode != 0:
        raise CaptureError(f"simctl {' '.join(args)} failed: {result.stdout.strip()}")
    return result.stdout.strip()


def current_appearance(device: str) -> str:
    value = simctl("ui", device, "appearance").lower()
    if value not in {"light", "dark"}:
        raise CaptureError(f"Unexpected simulator appearance: {value!r}")
    return value


def set_appearance(device: str, appearance: str) -> None:
    if appearance not in {"light", "dark"}:
        raise CaptureError(f"Unsupported appearance {appearance!r}")
    simctl("ui", device, "appearance", appearance)


def find_xctestrun(derived: Path) -> Path:
    products = derived / "Build" / "Products"
    matches = sorted(products.glob("CalCo-E2E_iphonesimulator*.xctestrun"))
    if not matches:
        raise CaptureError(f"No CalCo-E2E xctestrun under {products}")
    return matches[0]


def run_variant(
    xctestrun: Path,
    device: str,
    appearance: str,
    tests: list[str],
    target: Path,
) -> dict:
    target.mkdir(parents=True, exist_ok=True)
    result_bundle = target / "result.xcresult"
    if result_bundle.exists():
        shutil.rmtree(result_bundle)
    argv = [
        XCODEBUILD,
        "-xctestrun", str(xctestrun),
        "-destination", f"platform=iOS Simulator,id={device}",
        *[f"-only-testing:{name}" for name in tests],
        "-resultBundlePath", str(result_bundle),
        "test-without-building",
    ]
    process = run(argv)
    (target / "run.log").write_text(process.stdout, encoding="utf-8")
    passed = re.findall(r"Test Case '-\[CalCoUITests\.[^ ]+ ([^']+)\]' passed", process.stdout)
    failed = re.findall(r"Test Case '-\[CalCoUITests\.[^ ]+ ([^']+)\]' failed", process.stdout)
    green = (
        process.returncode == 0
        and (
            "** TEST SUCCEEDED **" in process.stdout
            or "** TEST EXECUTE SUCCEEDED **" in process.stdout
        )
        and not failed
    )
    if not green:
        raise CaptureError(
            f"{appearance} variant did not pass (exit={process.returncode}, "
            f"failed={failed}); see {target / 'run.log'}"
        )

    attachments = target / "attachments"
    if attachments.exists():
        shutil.rmtree(attachments)
    export = run([
        "xcrun", "xcresulttool", "export", "attachments",
        "--path", str(result_bundle),
        "--output-path", str(attachments),
    ])
    if export.returncode != 0:
        raise CaptureError(f"Attachment export failed: {export.stdout.strip()}")

    screenshots = target / "screenshots"
    if screenshots.exists():
        shutil.rmtree(screenshots)
    screenshots.mkdir(parents=True)
    copied = []
    for png in sorted(attachments.rglob("*.png")):
        destination = screenshots / png.name
        shutil.copy2(png, destination)
        copied.append(str(destination))

    metadata: list[str] = []
    for text in sorted(attachments.rglob("*.txt")):
        if "visual-metadata" in text.name:
            metadata.append(text.read_text(encoding="utf-8", errors="replace"))

    return {
        "appearance": appearance,
        "textSizeVariants": ["default", "AX5"],
        "tests": tests,
        "passedTestCases": sorted(set(passed)),
        "failedTestCases": sorted(set(failed)),
        "resultBundle": str(result_bundle),
        "runLog": str(target / "run.log"),
        "screenshots": copied,
        "visualMetadata": metadata,
        "visualApproval": "PENDING_PARENT_MANUAL_REVIEW",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=DEVICE)
    parser.add_argument("--derived", required=True, help="build-for-testing DerivedData root")
    parser.add_argument("--out", required=True, help="output directory for screenshots/manifest")
    parser.add_argument("--appearances", nargs="+", default=DEFAULT_APPEARANCES)
    parser.add_argument("--test", action="append", dest="tests", default=None)
    args = parser.parse_args()

    tests = args.tests or DEFAULT_TESTS
    out = Path(args.out).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    xctestrun = find_xctestrun(Path(args.derived).expanduser().resolve())

    # Ensure the device is booted before changing its appearance.
    boot = run(["xcrun", "simctl", "bootstatus", args.device, "-b"])
    if boot.returncode != 0:
        raise CaptureError(f"Could not boot target device: {boot.stdout.strip()}")

    original = current_appearance(args.device)
    manifest = {
        "device": args.device,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "originalAppearance": original,
        "variants": [],
    }
    try:
        for appearance in args.appearances:
            set_appearance(args.device, appearance)
            manifest["variants"].append(
                run_variant(xctestrun, args.device, appearance, tests, out / appearance)
            )
    finally:
        set_appearance(args.device, original)
        manifest["restoredAppearance"] = current_appearance(args.device)

    manifest_path = out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"visual QA manifest: {manifest_path}")
    for variant in manifest["variants"]:
        print(
            f"{variant['appearance']}: {len(variant['passedTestCases'])} passed, "
            f"{len(variant['screenshots'])} screenshots, "
            f"approval={variant['visualApproval']}"
        )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CaptureError as error:
        print(f"capture error: {error}", file=sys.stderr)
        sys.exit(2)
