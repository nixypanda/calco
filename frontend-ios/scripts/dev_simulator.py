#!/usr/bin/env python3
"""Build and run the native CalCo Debug app (just recipes, not a build tool).

Used by the ``dev-frontend-ios``, ``dev-frontend-ipados`` and
``dev-frontend-macos`` just recipes. It keeps Apple tools isolated from the
Nix dev shell (which shadows xcrun and injects SDKROOT / NIX_* / LD_* flags),
resolves simulators dynamically from ``simctl`` instead of hardcoded UDIDs,
and never erases, shuts down, or otherwise changes an already-booted
simulator.

Safety / verification seams:
  * CALCO_DEV_IOS_DRY_RUN=1  resolve and print commands, execute none of them.
    Only explicit true values (1/true/yes/on, case-insensitive) enable it;
    0/false/no/off/empty/unset mean "execute" (the normal recipe path).
  * CALCO_SIMCTL_JSON=FILE   resolve against a saved ``simctl list devices -j``
                             payload instead of calling simctl (for tests).
                             A missing or malformed file is a friendly usage
                             error, not a traceback.
  * CALCO_IOS_SIM_UDID=UDID  pin an exact simulator when names are ambiguous.
  * CALCO_XCODE_DEVELOPER_DIR=PATH  override the Xcode Developer directory.

Dry-run still queries the installed device list (read-only ``simctl list
devices -j``, or the saved JSON) so resolution is real; it never boots,
installs, launches, erases or shuts down anything.

No shell is used to run commands: every subprocess gets an argument vector,
so label/UDID values cannot be interpreted as shell syntax. Signing-related
environment variables are copied by name only, and their values are never
printed (not even in dry-run output).
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
DEVELOPER_DIR_ENV = "CALCO_XCODE_DEVELOPER_DIR"
UDID_ENV = "CALCO_IOS_SIM_UDID"
SIMCTL_JSON_ENV = "CALCO_SIMCTL_JSON"
DRY_RUN_ENV = "CALCO_DEV_IOS_DRY_RUN"

PROJECT = os.path.join(REPO_ROOT, "frontend-ios", "CalCo.xcodeproj")
DERIVED_DATA = os.path.join(REPO_ROOT, "frontend-ios", "build", "dev")
SCHEME = "CalCo"
CONFIGURATION = "Debug"
BUNDLE_ID = "dev.calco.CalCo"
APP_NAME = "CalCo.app"

# Labels are mapped to EXACT simulator names. There is deliberately no
# "closest model" fallback: a missing device is an error, not a guess.
DEVICE_LABELS = {
    "ios": {
        "mini": "iPhone 13 mini",
        "18-pro": "iPhone 18 Pro",
        "duo": "iPhone Duo",
    },
    "ipados": {
        "mini": "iPad mini (A17 Pro)",
        "air": "iPad Air 11-inch (M4)",
    },
}

JUST_COMMAND = {
    "ios": "just dev-frontend-ios LABEL",
    "ipados": "just dev-frontend-ipados LABEL",
    "macos": "just dev-frontend-macos",
}

# Signing material must survive the environment reset, but Nix linker/SDK
# variables must not. Matching by *name* keeps CODE_SIGN_STYLE and
# OTHER_CODE_SIGN_FLAGS next to CODE_SIGN_IDENTITY, and covers any
# PROVISIONING_*/KEYCHAIN_* variable without enumerating them. DEVELOPMENT_TEAM
# is added explicitly because it carries no shared prefix. Values are copied
# straight through and never printed, so secrets stay out of logs and
# dry-run output.
SIGNING_NAME_MARKERS = ("CODE_SIGN", "PROVISIONING_", "KEYCHAIN", "DEVELOPMENT_TEAM")

# Only these explicit values enable an opt-in boolean environment flag.
TRUE_FLAG_VALUES = frozenset({"1", "true", "yes", "on"})

APPLE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


class UsageError(Exception):
    """A bad label, missing device, bad saved JSON, or ambiguous target."""


def env_flag_is_true(name: str) -> bool:
    """Return True only for an explicit truthy value of an opt-in env flag.

    Unset, empty, 0, false, no and off all mean "not enabled". Matching is
    case-insensitive and tolerates surrounding whitespace so a stray space in
    a shell assignment cannot silently switch the recipe into execute mode.
    """
    value = os.environ.get(name)
    if value is None:
        return False
    return value.strip().lower() in TRUE_FLAG_VALUES


def is_signing_env_key(key: str) -> bool:
    """Whether an environment variable *name* carries signing material.

    Deliberately name-based: the value may be a secret, so it is only ever
    copied into the Apple-tool environment and never logged or printed.
    """
    return any(marker in key for marker in SIGNING_NAME_MARKERS)


def developer_dir() -> str:
    """Resolve the one DEVELOPER_DIR every Apple tool call will use."""
    path = os.environ.get(DEVELOPER_DIR_ENV) or DEFAULT_DEVELOPER_DIR
    if not os.path.isdir(path):
        raise UsageError(
            f"Xcode Developer directory not found: {path}\n"
            f"Set {DEVELOPER_DIR_ENV} to a valid Xcode.app/Contents/Developer "
            "directory (needed when a simulator ships with a different Xcode)."
        )
    return path


def apple_env(dev_dir: str) -> dict[str, str]:
    """A minimal Apple-tool environment; no Nix/SDK/linker contamination.

    HOME and TMPDIR are preserved (keychain, Simulator data, temp files).
    DEVELOPER_DIR is always set explicitly. Only variables whose names look
    like signing material are copied from the caller's environment, and their
    values are never printed.
    """
    env = {
        "PATH": APPLE_PATH,
        "HOME": os.environ.get("HOME") or os.path.expanduser("~"),
        "TMPDIR": os.environ.get("TMPDIR") or tempfile.gettempdir(),
        "USER": os.environ.get("USER") or "",
        "LOGNAME": os.environ.get("LOGNAME") or os.environ.get("USER") or "",
        "SHELL": "/bin/sh",
        "TERM": os.environ.get("TERM") or "dumb",
        "DEVELOPER_DIR": dev_dir,
    }
    for key, value in os.environ.items():
        if value and is_signing_env_key(key):
            env[key] = value
    return env


def validate_target_and_label(target: str, label: str | None) -> str | None:
    """Validate args, returning the exact simulator name (None for macOS)."""
    if target == "macos":
        if label is not None:
            raise UsageError(
                f"macOS takes no device label (got '{label}').\n"
                f"Usage: {JUST_COMMAND['macos']}"
            )
        return None
    labels = DEVICE_LABELS[target]
    if not label:
        raise UsageError(
            f"Missing device label for {target}.\n"
            f"Usage: {JUST_COMMAND[target]}  "
            f"(labels: {', '.join(labels)})"
        )
    if label not in labels:
        raise UsageError(
            f"Unknown {target} label '{label}'.\n"
            f"Usage: {JUST_COMMAND[target]}  "
            f"(labels: {', '.join(labels)})"
        )
    return labels[label]


def simctl_devices(dev_dir: str, simctl_json: str | None) -> dict:
    """Return the parsed ``simctl list devices -j`` payload (read-only)."""
    if simctl_json:
        try:
            with open(simctl_json, encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise UsageError(
                f"Could not read {SIMCTL_JSON_ENV}={simctl_json}: {exc}"
            ) from exc
    try:
        proc = subprocess.run(
            ["/usr/bin/xcrun", "simctl", "list", "devices", "-j"],
            env=apple_env(dev_dir),
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise UsageError(
            f"Could not list simulators using DEVELOPER_DIR={dev_dir}: {exc}"
        ) from exc
    return json.loads(proc.stdout)


def ios_devices(data: dict) -> list[dict]:
    """Flatten iOS/iPadOS simulators; ignore watchOS/tvOS runtimes."""
    devices: list[dict] = []
    for runtime, entries in (data.get("devices") or {}).items():
        if not any(tag in runtime for tag in ("iOS", "iPadOS")):
            continue
        for entry in entries:
            devices.append(
                {
                    "name": entry.get("name", ""),
                    "udid": entry.get("udid", ""),
                    "state": entry.get("state", ""),
                    "runtime": runtime,
                }
            )
    return devices


def available_names(data: dict, target: str | None = None) -> str:
    """List installed names for one platform (iPhone vs iPad), never both.

    Resolution itself matches exact names; this is only for the actionable
    "installed simulators" hint, so it is filtered by the requested platform
    to avoid suggesting an iPad when an iPhone label failed (and vice versa).
    """
    devices = ios_devices(data)
    if target == "ios":
        devices = [d for d in devices if d["name"].startswith("iPhone")]
    elif target == "ipados":
        devices = [d for d in devices if d["name"].startswith("iPad")]
    names = sorted({d["name"] for d in devices if d["name"]})
    return ", ".join(names) if names else "(none)"


def resolve_device(
    target: str,
    label: str,
    data: dict,
    udid_override: str | None = None,
) -> tuple[dict, str]:
    """Resolve a label to one simulator and an optional explanatory note.

    Order: explicit UDID override, then a unique booted match, then a stable
    (sorted-by-UDID) choice among shutdown matches. Multiple booted matches
    are ambiguous and require an explicit UDID override.
    """
    expected_name = validate_target_and_label(target, label)
    assert expected_name is not None
    matches = [d for d in ios_devices(data) if d["name"] == expected_name]

    if udid_override:
        pinned = [d for d in matches if d["udid"] == udid_override]
        if not pinned:
            raise UsageError(
                f"{UDID_ENV}={udid_override} is not an installed "
                f"'{expected_name}' simulator for label '{label}'.\n"
                f"Installed {target} simulators: {available_names(data, target)}"
            )
        return pinned[0], f"UDID pinned via {UDID_ENV}."

    if not matches:
        hint = ""
        if label == "18-pro":
            hint = (
                "\nNo fallback model is used. The installed Xcode 26.6 does not "
                "ship 'iPhone 18 Pro'; install a compatible Xcode/runtime and "
                f"set {DEVELOPER_DIR_ENV} to its Developer directory."
            )
        elif label == "duo":
            hint = (
                "\nThe 'duo' label requires a compatible Xcode/runtime that "
                "provides 'iPhone Duo' (not present in Xcode 26.6). Set "
                f"{DEVELOPER_DIR_ENV} to that Xcode's Developer directory and "
                "retry."
            )
        raise UsageError(
            f"No installed simulator named '{expected_name}' for {target} "
            f"label '{label}'.{hint}\n"
            f"Installed {target} simulators: {available_names(data, target)}\n"
            f"Pin a specific device with {UDID_ENV}=<UDID> if needed."
        )

    booted = [d for d in matches if d["state"] == "Booted"]
    if len(booted) == 1:
        return booted[0], ""
    if len(booted) > 1:
        udids = ", ".join(sorted(d["udid"] for d in booted))
        raise UsageError(
            f"Multiple booted simulators named '{expected_name}' "
            f"({udids}). Pin one with {UDID_ENV}=<UDID>."
        )

    # No booted match: choose deterministically, never by list order.
    matches.sort(key=lambda d: d["udid"])
    chosen = matches[0]
    note = (
        f"{len(matches)} shut-down simulators named '{expected_name}'; chose "
        f"UDID {chosen['udid']} (lowest UDID). "
        f"Pin another with {UDID_ENV}=<UDID>."
    )
    return chosen, note


def build_command(destination: str) -> list[str]:
    return [
        "/usr/bin/xcodebuild",
        "-project",
        PROJECT,
        "-scheme",
        SCHEME,
        "-configuration",
        CONFIGURATION,
        "-destination",
        destination,
        "-derivedDataPath",
        DERIVED_DATA,
        "-quiet",
        "build",
    ]


def simulator_plan(device: dict) -> tuple[list[list[str]], str]:
    """Build + (only if needed) boot + install + launch + focus window."""
    udid = device["udid"]
    destination = f"platform=iOS Simulator,id={udid}"
    app = os.path.join(DERIVED_DATA, "Build", "Products", "Debug-iphonesimulator", APP_NAME)
    commands = [build_command(destination)]
    # Never boot/shutdown/erase an already-booted simulator (e.g. the
    # user's iPhone 13 mini). Boot only a shutdown target when necessary.
    if device["state"] != "Booted":
        commands.append(["/usr/bin/xcrun", "simctl", "boot", udid])
    commands += [
        ["/usr/bin/xcrun", "simctl", "install", udid, app],
        ["/usr/bin/xcrun", "simctl", "launch", udid, BUNDLE_ID],
        ["/usr/bin/open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid],
    ]
    return commands, app


def macos_plan() -> tuple[list[list[str]], str]:
    app = os.path.join(DERIVED_DATA, "Build", "Products", "Debug", APP_NAME)
    commands = [build_command("generic/platform=macOS")]
    commands.append(["/usr/bin/open", app])
    return commands, app


def run_plan(commands: list[list[str]], dev_dir: str, dry_run: bool) -> None:
    for command in commands:
        rendered = shlex.join(command)
        if dry_run:
            print(f"[dry-run] {rendered}")
            continue
        print(f"+ {rendered}", flush=True)
        subprocess.run(command, env=apple_env(dev_dir), check=True)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="dev_simulator.py",
        description="Build and run the native CalCo Debug app.",
    )
    parser.add_argument("target", choices=("ios", "ipados", "macos"))
    parser.add_argument("label", nargs="?")
    parser.add_argument("--dry-run", action="store_true", help="print commands, run none")
    parser.add_argument("--simctl-json", help="resolve against a saved simctl JSON payload")
    parser.add_argument("--udid", help="pin an exact simulator UDID")
    args = parser.parse_args(argv)
    args.dry_run = args.dry_run or env_flag_is_true(DRY_RUN_ENV)
    args.simctl_json = args.simctl_json or os.environ.get(SIMCTL_JSON_ENV)
    args.udid = args.udid or os.environ.get(UDID_ENV)
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        dev_dir = developer_dir()

        if args.target == "macos":
            validate_target_and_label("macos", args.label)
            commands, app = macos_plan()
            target_line = f"macOS native app -> {app}"
            note = ""
        else:
            device, note = resolve_device(args.target, args.label, simctl_devices(
                dev_dir, args.simctl_json
            ), args.udid)
            commands, app = simulator_plan(device)
            target_line = (
                f"{args.target} '{device['name']}' "
                f"(UDID {device['udid']}, {device['state']}) -> {app}"
            )
    except UsageError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(f"Target: {target_line}")
    print(f"DEVELOPER_DIR: {dev_dir}")
    if note:
        print(f"Note: {note}")
    print("Debug app uses http://localhost:3001 (run `just dev-backend`); "
          "E2E Test builds use http://127.0.0.1:3002 via the CalCo-E2E scheme.")
    run_plan(commands, dev_dir, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
