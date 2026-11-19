# CalCo native client (`frontend-ios`)

A native SwiftUI client for CalCo, targeting **iOS 26, iPadOS 26 and macOS 26**.
It uses only Apple frameworks (SwiftUI, Foundation, XCTest); there are no
Swift Package or third-party dependencies. UI uses native SwiftUI styling with
no custom design system.

This directory currently contains the Xcode scaffold, the app entry point,
build configuration and resources. Domain/API/feature implementation lives in
the shared source directories and is owned by the feature implementors.

## Requirements

- macOS with **Xcode 26.6** installed at `/Applications/Xcode.app`.
- Force that Xcode for command-line builds with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not rely on a
  global `xcode-select` setting.
- iPadOS is built as part of the iOS target (`TARGETED_DEVICE_FAMILY = 1,2`);
  macOS is a second destination of the same target, built natively (not
  Mac Catalyst). Minimum deployment target is 26.0 on every platform.

Open the project in the right Xcode with:

```bash
open -a /Applications/Xcode.app frontend-ios/CalCo.xcodeproj
```

## Development commands (`just`)

From the repository root (inside `nix develop` as usual):

| Recipe | What it does |
| :--- | :--- |
| `just dev-frontend-web` | Web frontend (Vite) on `localhost:1234` |
| `just dev-frontend` | Old name for the web server (alias of `dev-frontend-web`) |
| `just dev` | PostgreSQL + backend + **web** frontend, as before |
| `just dev-frontend-ios LABEL` | Build Debug `CalCo`, install/launch on the chosen iPhone simulator |
| `just dev-frontend-ipados LABEL` | Same on the chosen iPad simulator |
| `just dev-frontend-macos` | Build Debug `CalCo` natively for macOS and open the app |

Labels are exact, with no "closest model" fallback:

| Recipe | Label | Simulator name |
| :--- | :--- | :--- |
| `dev-frontend-ios` | `mini` | `iPhone 13 mini` |
| `dev-frontend-ios` | `18-pro` | `iPhone 18 Pro` |
| `dev-frontend-ios` | `duo` | `iPhone Duo` |
| `dev-frontend-ipados` | `mini` | `iPad mini (A17 Pro)` |
| `dev-frontend-ipados` | `air` | `iPad Air 11-inch (M4)` |

An unknown label, or a label whose simulator is not installed, exits with a
clear error and the list of installed simulators for that platform only
(iPhones for `dev-frontend-ios`, iPads for `dev-frontend-ipados`). The installed
Xcode 26.6 has no `iPhone 18 Pro` or `iPhone Duo`: `18-pro` and `duo` are
**not** silently mapped to another model (in particular, not to
`iPhone 17 Pro`). To use one of them, install the matching Xcode/runtime and
point the recipes at it:

```bash
CALCO_XCODE_DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
    just dev-frontend-ios 18-pro
```

Native recipes never start PostgreSQL or the backend. The `Debug` app talks to
`http://localhost:3001`, so start it separately with `just dev-backend` (plus
`just db-up` / `just migrate-backend` when needed). The isolated E2E app is a
different build — `CalCo-E2E` / `Test` configuration on
`http://127.0.0.1:3002` — and is not launched by these recipes; see
[Tests](#tests).

Simulator safety and overrides:

- Devices are resolved dynamically from `xcrun simctl list devices -j`; no
  UDIDs are hardcoded.
- Duplicate names resolve deterministically: a unique booted match wins,
  otherwise the lowest UDID is chosen and printed. If several matches are
  booted, the recipe asks you to pin one.
- Set `CALCO_IOS_SIM_UDID=<UDID>` to pin an exact simulator.
- The recipes never `erase` or `shutdown` a simulator. An already-booted
  device (your `iPhone 13 mini`) is installed/launched as-is; only a shutdown
  target is booted. The matching Simulator window is then brought forward.
- `CALCO_DEV_IOS_DRY_RUN=1` resolves the target and prints the exact commands
  without booting, installing, launching, or opening anything — useful for
  checking a label or override safely. Dry-run is **read-only with respect to
  simulator state**, but it still queries the installed device list via
  `xcrun simctl list devices -j` (or the saved JSON below) so resolution is
  real. It never changes a device.
  Only explicit truthy values enable it: `1`, `true`, `yes` or `on`
  (case-insensitive). `0`, `false`, `no`, `off`, an empty value and an unset
  variable all mean **execute** — the normal recipe path. The `--dry-run`
  flag works too and overrides a false environment value.
- `CALCO_SIMCTL_JSON=FILE` resolves against a saved `simctl list devices -j`
  payload instead of calling simctl (used by the script tests). A missing or
  malformed file produces a friendly `CALCO_SIMCTL_JSON` usage error, not a
  traceback.
- All Apple tools use an explicit `DEVELOPER_DIR` (the default above, or
  `CALCO_XCODE_DEVELOPER_DIR`) and run in a cleaned environment: the Nix
  shell's `xcrun`, `SDKROOT`, `NIX_*`, `LD_*` and other SDK/linker flags are
  dropped, while `HOME`, `TMPDIR` and code-signing settings are preserved.
  Signing-related variables are kept by **name** (`CODE_SIGN*`,
  `PROVISIONING_*`, `KEYCHAIN*`, plus `DEVELOPMENT_TEAM`), which covers
  `CODE_SIGN_STYLE` and `OTHER_CODE_SIGN_FLAGS`. Their values are copied
  straight into the Apple-tool environment and are never printed — not even
  in dry-run output.

Check the helper in isolation (no simulator state changes):

```bash
just test-ios-scripts
```

## Build commands

Run from the repository root (or `cd frontend-ios` and drop the `frontend-ios/`
prefix).

```bash
# Development build for the iOS Simulator (backend: http://localhost:3001)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build

# Native macOS build, same development backend
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo \
  -configuration Debug -destination 'generic/platform=macOS' build

# E2E / test build (isolated backend: http://127.0.0.1:3002)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo-E2E \
  -configuration Test -destination 'generic/platform=iOS Simulator' build

# Unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo \
  -configuration Debug -destination 'generic/platform=iOS Simulator' test

# Release build (HTTPS only; explicit CALCO_API_BASE_URL is mandatory)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo \
  -configuration Release -destination 'generic/platform=macOS' \
  CALCO_API_BASE_URL=https://your-host.example.com build
```

The `CalCo` scheme uses `Debug` for Run/Test. The shared `CalCo-E2E` scheme uses
the `Test` configuration (127.0.0.1:3002) for Run/Test. Device builds need a
signing team; set `DEVELOPMENT_TEAM` in Xcode or pass
`DEVELOPMENT_TEAM=XXXXXXXXXX` to `xcodebuild`. Simulator and macOS builds need
no team.

## Source layout and discovery

| Path | Owner | Contents |
| :--- | :--- | :--- |
| `App/CalCoApp.swift` | scaffold (reserved) | The only `@main` entry point |
| `App/` (other files) | app implementor | Navigation / wiring |
| `API/`, `Data/`, `Store/`, `Features/` | feature implementors | Network, models, state, features |
| `Components/`, `Views/` | shared | Reusable UI |
| `Resources/` | scaffold | `Localizable.xcstrings` |
| `Tests/` | shared | Unit tests |
| `Config/` | scaffold | xcconfigs and Info.plists |
| `CalCo.xcodeproj/` | scaffold | Project and shared schemes |

**Source discovery is automatic.** Every shared source directory is an Xcode
*synchronized folder* (`PBXFileSystemSynchronizedRootGroup`): any `.swift` file
added under `App/`, `API/`, `Data/`, `Store/`, `Features/`, `Components/`,
`Views/` or `Resources/` is compiled into the `CalCo` app target, and anything
under `Tests/` into `CalCoTests`, **without editing `project.pbxproj`**. Nested
subdirectories are included too. Do not add a second `@main`; keep the app
entry point in `App/CalCoApp.swift`.

## API base URL configuration

`CALCO_API_BASE_URL` is a per-configuration build setting on the `CalCo` app
target in `CalCo.xcodeproj/project.pbxproj`. The quoted values there are baked
into each Info.plist as `CALCOAPIBaseURL` through
`$(CALCO_API_BASE_URL)`. The xcconfigs only set `CALCO_ENVIRONMENT` and shared
build settings.

| Configuration | `CALCO_API_BASE_URL` build setting | App Transport Security |
| :--- | :--- | :--- |
| `Debug` | `http://localhost:3001` | Insecure HTTP allowed **only** for `localhost` and `127.0.0.1` |
| `Test` | `http://127.0.0.1:3002` | Same narrow localhost-only exception (E2E backend) |
| `Release` | `https://calco.example.com` | No exceptions — HTTPS only |

The `Test` app uses a distinct bundle identifier (`dev.calco.CalCo.Test`) and
`127.0.0.1` so its cookie jar cannot collide with the `Debug` app on
`localhost:3001`; browsers and WebKit ignore ports when scoping cookies.

**Release requires an explicit URL.** `https://calco.example.com` is only a
placeholder: the app target's "Validate Release API base URL" build phase fails
a Release build whose URL is still that placeholder, is empty, or is not
HTTPS. Set the real deployment URL before archiving — either edit
`CALCO_API_BASE_URL` for the `Release` configuration in
`CalCo.xcodeproj/project.pbxproj`, or override it on the command line
(command-line assignments take precedence over project build settings):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo \
  -configuration Release -destination 'generic/platform=macOS' \
  CALCO_API_BASE_URL=https://your-host.example.com build
```

Release must be HTTPS. Do not add an ATS exception to
`Config/Info-Release.plist` to accommodate a plain-HTTP server.

**Runtime override.** `CalCoRuntimeConfiguration.baseURL` in
`App/CalCoApp.swift` checks the `CALCO_API_BASE_URL` environment variable
first, then falls back to the `CALCOAPIBaseURL` baked into Info.plist. Feature
code should use that value instead of hard-coding a host. Set the environment
variable in Xcode's Run/Test scheme (Arguments → Environment Variables) or in
the test host environment for E2E runs. No credentials are stored in this
scaffold, and the override does not relax Release ATS: a non-loopback HTTP host
still needs a Debug/Test-only exception in `Info-Debug.plist` /
`Info-Test.plist`.

## Simulator vs. real device

- **Simulator (and native macOS):** `localhost` is the machine running Xcode,
  so `http://localhost:3001` reaches the dev backend started with
  `just dev-backend` (the backend binds `0.0.0.0:3001`). The isolated E2E
  backend is reached at `http://127.0.0.1:3002` with the `Test` configuration.
- **Real iPhone/iPad:** `localhost` means *the device itself*, not the Mac.
  To talk to a backend on your Mac, use the Mac's LAN address instead, e.g.
  `http://192.168.1.20:3001`; keep the backend bound to `0.0.0.0` and make sure
  the device is on the same network and the Mac's firewall permits the port.
  Because the ATS exception is deliberately narrow, add that specific LAN IP to
  `NSExceptionDomains` in `Config/Info-Debug.plist` (or `Info-Test.plist`) for
  device E2E only. Never carry that exception into Release.
- A runtime `CALCO_API_BASE_URL` override changes the URL the app requests, but
  it does not change ATS — host exceptions still come from the active
  Info.plist.

## Localization

There is one English-only String Catalog: `Resources/Localizable.xcstrings`
(`sourceLanguage = en`, no other locales). `SWIFT_EMIT_LOC_STRINGS = YES`
ensures it is compiled.

To add a string, use `String(localized: "feature.key")` or `Text("feature.key")`
and add a matching entry under `strings` with an English `stringUnit` value.
Keep keys in alphabetical order in the single catalog — that keeps merges
simple when several feature agents add keys concurrently. Do not create extra
locales or extra String Catalog tables.

Keys currently defined: `CalCo`, `Native app scaffold`, and all static
`String(localized:)` call-site keys under `auth.*`, `diary.*`, `foodDetail.*`
(including `foodDetail.mealSlot.*`), `settings.*` (goals, slots, status,
discard, keyboard and errors), and `search.*`, including error keys such as
`diary.error.network`, `diary.error.sessionExpired`, `diary.refresh`,
`diary.sessionExpired.title`, `foodDetail.error.*` and `search.error.generic`.

The catalog currently has these format strings:
`diary.editor.delete.failedWithBarrier` (`%@`),
`diary.mutation.deleted.blockedPending` (`%lld`),
`settings.goals.status.savedFrom` (`%@`, the localized effective date), and
`foodDetail.pending.banner.count` (`%lld`). They have single English
translations and no plural/number variations; `settings.goals.status.savedFrom`
uses `String(format:)` with an already-formatted date. If a feature introduces
a count-based format string, add its plural variations in the String Catalog
rather than concatenating numbers in code. Interpolated `Text("\(value) …")`
strings are not catalog keys and must be reworked by the owning feature if they
need localization.

## Tests

`Tests/` is a synchronized folder for the `CalCoTests` unit-test target, which
depends on and hosts the app target (`TEST_HOST` is set per SDK). Tests use
XCTest. Most tests use `@testable import CalCo`; no network or database is
required.

All test files import the app module normally with `@testable import CalCo`;
no module aliases or per-import Swift flags are used. The `Test` configuration
does define the `DEBUG` and `CALCO_TEST` Swift compilation conditions (for the
loopback-HTTP allowance and the test-only `diary.fetchCompletionCount` marker),
but those are build settings rather than special flags needed by the test
imports. If `AuthFeature` ever becomes a real framework target, add that
framework to `CalCoTests` and change the auth tests' import then.

### XCUITest UI tests

`UITests/` is a synchronized folder for the `CalCoUITests` UI-test target. It is
a black-box target (no `@testable import`) driven by stable accessibility
identifiers such as `auth.login.*`, `search.field`, `search.result.*`,
`diary.addFood.*`, `diary.summary.calories`, `diary.log.*` and
`foodDetail.*`. It is wired into the shared **`CalCo-E2E`** scheme only — the
`CalCo` scheme is unchanged.

The app under test is always the isolated **`dev.calco.CalCo.Test`** bundle
against **`http://127.0.0.1:3002`**. It never targets the `Debug` app or the
development backend on `localhost:3001`.

Build the app and both test bundles for the simulator:

```bash
DERIVED="${TMPDIR%/}/calco-e2e-derived"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo-E2E \
  -configuration Test -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" build-for-testing
```

The default smoke needs no credentials and writes nothing:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project frontend-ios/CalCo.xcodeproj -scheme CalCo-E2E \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -derivedDataPath "$DERIVED" \
  -only-testing:CalCoUITests/CalCoSmokeUITests/testLaunchShowsLoginOrDiary \
  test-without-building
```

It accepts only the sign-in form (`auth.login.username`,
`auth.login.password`, `auth.login.submit`) or a loaded diary
(`diary.summary.calories`). Error, expired, retry, loading and configuration
states are failures, not a valid initial state.

The `CalCo-E2E` scheme selects the project's `Test` configuration. That
configuration defines Swift's `DEBUG` compilation condition for the
loopback-HTTP allowance and `CALCO_TEST` for the test-only
`diary.fetchCompletionCount` accessibility marker; no command-line Swift flag
override is needed. The marker is compiled only for the Test app, so Debug and
Release builds contain no `diary.fetchCompletionCount` element or VoiceOver
pollution. If a Test build reports an invalid HTTPS API base URL, do not run
credentialed E2E until the Test configuration is corrected.

#### Credentialed E2E

The credential path currently requires the **iOS Simulator**; the macOS
destination is not supported by this simulator-only E2E harness, because macOS secure password entry is not supported/verified. It also requires a
seeded normal user and the fixture food `E2E Test Food a2c0252a5298` on the
isolated backend.

The tests always return to a fresh login: if a Test-app session was restored,
they sign it out first, and a restored session never counts as proof of login.
Password entry never calls `typeText`. It writes the password to the simulator
shared pasteboard, sends Cmd+V, verifies that the secure field changed and is
masked, and then clears the pasteboard on every exit path. If any step cannot
be verified, the test skips instead of falling back to `typeText`. The system
"Save Password?" sheet is dismissed with **Not Now**; tests never choose Save.
Tests add no screenshots or attachments of their own.

Credentials must never be committed, placed in a scheme, or placed in an
xcconfig. Keep a private JSON file outside the repository:

```bash
umask 077
mkdir -p "$HOME/.private" && chmod 700 "$HOME/.private"
cat > "$HOME/.private/calco-e2e.json" <<'JSON'
{"username":"<user>","password":"<password>"}
JSON
chmod 600 "$HOME/.private/calco-e2e.json"
```

For each credentialed run, copy the built xctestrun into a private `0700`
directory, make it `0600`, and inject `CALCO_E2E_CREDENTIALS_JSON` only into
the `CalCoUITests` runner environment. Do **not** add it to the scheme or to
`UITargetAppEnvironmentVariables`. The xctestrun expects its products next to
it, so link `Test-iphonesimulator` into the same private directory:

```bash
DERIVED="${TMPDIR%/}/calco-e2e-derived"
PRIVATE_RUN="$(mktemp -d "${TMPDIR%/}/calco-e2e-run.XXXXXX")"
chmod 700 "$PRIVATE_RUN"
XCTESTRUN="$(find "$DERIVED/Build/Products" -maxdepth 1 \
  -name 'CalCo-E2E_iphonesimulator*.xctestrun' -print -quit)"
cp "$XCTESTRUN" "$PRIVATE_RUN/run.xctestrun"
chmod 600 "$PRIVATE_RUN/run.xctestrun"
ln -s "$DERIVED/Build/Products/Test-iphonesimulator" \
  "$PRIVATE_RUN/Test-iphonesimulator"
python3 - "$PRIVATE_RUN/run.xctestrun" "$HOME/.private/calco-e2e.json" <<'PY'
import json
import plistlib
import sys

xctestrun, credentials_path = sys.argv[1], sys.argv[2]
credentials = json.load(open(credentials_path))
with open(xctestrun, "rb") as handle:
    data = plistlib.load(handle)
data["CalCoUITests"]["EnvironmentVariables"]["CALCO_E2E_CREDENTIALS_JSON"] = \
    json.dumps(credentials)
with open(xctestrun, "wb") as handle:
    plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
PY
```

Run both credentialed tests with that private xctestrun:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -xctestrun "$PRIVATE_RUN/run.xctestrun" \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -only-testing:CalCoUITests/CalCoSmokeUITests/testSignInWhenCredentialsAvailable \
  -only-testing:CalCoUITests/VerticalSliceUITests/testLogE2ETestFoodFromSelectedDayDiary \
  -resultBundlePath "$PRIVATE_RUN/result.xcresult" \
  test-without-building 2>&1 | tee "$PRIVATE_RUN/run.log"
```

Before trusting the result, scan the result bundle and build log for the exact
password and its eight-character prefix. The scan prints counts only:

```bash
python3 - "$PRIVATE_RUN" "$HOME/.private/calco-e2e.json" <<'PY'
import json
import os
import sys

root, credentials_path = sys.argv[1], sys.argv[2]
password = json.load(open(credentials_path))["password"].encode()
needles = (password, password[:8])
exact = prefix = 0
for directory, _, files in os.walk(root):
    for name in files:
        if name == "run.xctestrun":
            continue
        with open(os.path.join(directory, name), "rb") as handle:
            data = handle.read()
        exact += data.count(needles[0])
        prefix += data.count(needles[1])
print("exact_password_hits", exact)
print("password_prefix_hits", prefix)
print("privacy_scan", "PASS" if exact == 0 and prefix == 0 else "FAIL")
PY
xcrun simctl pbcopy <SIMULATOR_UDID> < /dev/null
```

If the scan fails, treat the credentials as exposed, rotate them, and do not run
credentialed E2E again until the leak is fixed. The tests also clear the
pasteboard themselves on every exit path; the final `pbcopy` is belt-and-braces.

The vertical-slice test asserts identifier-based form state
(`foodDetail.mealSlot.picker` retains Breakfast, `foodDetail.unit.picker`
retains Gram, amount 100) plus the semantic accessibility labels for the two
text fields: `foodDetail.amount.field` must expose the English label `Amount`
and `foodDetail.notes.field` the English label `Notes`. Both fields are resolved
by their stable accessibility identifier on `.any` descendants, not by an
assumed control type — the single-line amount is a `UITextField`, while the
vertically scrolling notes field is a `UITextView` and would be invisible to a
`textFields` query. These label assertions share the credentialed journey, so
they only run when private credentials are supplied. It also asserts an
immediate return to the loaded diary after `foodDetail.submit`. Completion of a
real fetch is observed through the accessibility marker
`diary.fetchCompletionCount`, which `DiaryViewModel` advances only when a fetch
actually publishes fresh content; it is not inferred from a refresh button that
is already enabled or a diary that is already loaded. Because the app shell
also refreshes the diary automatically after a successful submit, the test waits
for that automatic fetch to complete first, then taps `diary.refresh` and waits
for the marker to advance again before asserting.

The refresh control is located as a *hittable* `diary.refresh` button (stable
identifier first, English accessibility label `Refresh` as a fallback for a
collapsed action). If the primary-action toolbar has collapsed on a narrow
device, the test reveals the overflow menu before re-querying. The overflow
locator accepts the iOS 26 label `More Items` as well as `More` (older iOS) and
a few identifier spellings, and only returns a control after proving it is
hittable — a fixed `label == "More"` lookup would miss `More Items`.

Baseline and post-refresh `diary.log.*` ID/label maps are collected across the
full scrollable list (not just the currently rendered cells) by walking until
both edges are observed. "At top" is detected by AX existence plus a visible,
non-empty frame of a stable first-section sentinel (`diary.summary.calories`,
its macro summaries, or `diary.fetchCompletionCount`) in the upper portion of
the screen — **not** by `isHittable`. The `diary.summary.calories` identifier is
attached to a SwiftUI `Group` that becomes an AX *container*: it exists but is
routinely not hittable, so a hittability-based top check can swipe forever even
though the summary is visibly at the top. The bottom is signalled by bounded
convergence (a few consecutive swipes that reveal no new rows). Swiping stops
on convergence or when the sentinel frame stops moving; a hard swipe ceiling is
only a safety net, so a long diary is not silently truncated and a healthy
traversal does not require dozens of blind swipes. Each snapshot records whether
both edges were reached and captures each row's label while it is on screen (a
later identifier re-query can fail once the row scrolls offscreen). The scroll
container is resolved from whichever collection/table/scroll view actually
contains the diary content, so the test is not tied to one SwiftUI `List`
backing type or an arbitrary `firstMatch`.

Because the diary did load, an incomplete traversal is a real **failure**
(`XCTFail`), not an inconclusive skip — only unmet environmental prerequisites
(no simulator paste path, no credentials) may call `XCTSkip`. The Calories
summary is read only after a successful return to the top, and the initial
`diary.fetchCompletionCount` must reach at least 1 before any baseline is
trusted.

After that refresh the test asserts exactly one newly observed UI row (using its
captured label) and an exact +100 kcal summary delta (100 Gram at 100 kcal/100
g). Those are claims about rendered rows and the displayed summary, **not**
about the number of persisted backend records: one new UI row is not proof of
exactly one new backend log. The test does not use a Back-button loop or
positional summary parsing.
