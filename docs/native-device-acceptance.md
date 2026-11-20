# Native device acceptance — Mac and iPad Air

Status: **iPad Air 11-inch (M4) UI PASS; Mac UI blocked by user decision;
iPhone Duo unavailable.** This is not full two-device UI acceptance.

- iPad Air 11-inch (M4): **7/7 passed, 0 failed, 0 skipped, 0 expected failures**
  in the latest portable run. The prior Library 44-point finding is resolved.
- Mac: native production unit **751/751 passed** with the one-line pasteboard
  compile fix applied; that is an actual run, not a diagnostic. The Mac branch
  is unchanged by the iOS-only Library fix. Mac UI executed **0 app tests** and
  failed runner initialization with `Timed out while enabling automation mode`.
  The user explicitly chose to leave Mac UI blocked; no permission change or
  retry is planned. This is one system/runner failure, not one failed product
  test.
- iPhone Duo: exact device/type is absent from Xcode 26.6; unavailable and not
  substituted.
- Unit results are not UI acceptance.

Compile evidence:

- Mac: `CalCo-E2E` Test `build-for-testing` for `platform=macOS,arch=arm64`
  succeeded; product is native `MacOSX` `CalCo.app` (arm64), minimum macOS 26.0.
- iPad Air 11-inch (M4): `build-for-testing` for
  `platform=iOS Simulator,id=C9CE77F1-89E8-4DF5-B101-871105BCED9B` succeeded.
- Shared derived data:
  `${TMPDIR%/}/opencode/CalCoPortable-Mac-20261119-235354`.

## Actual runtime record — 2026-11-20

### Latest iPad acceptance — PASS

```text
/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-portable-ui-ipad-20261120-toolbar-fix-menu.xcresult
device: iPad Air 11-inch (M4)
deviceId: C9CE77F1-89E8-4DF5-B101-871105BCED9B
result: Passed
totalTestCount: 7
passedTests: 7
failedTests: 0
skippedTests: 0
expectedFailures: 0
```

The Library Add action was changed on iOS only to a native menu with
`.menuStyle(.button)`, `.buttonStyle(.plain)`, `.frame(width: 44, height: 44)`,
`.fixedSize()`, and `.contentShape(Rectangle())`. The Mac branch is unchanged.
Post-fix frame evidence:

```text
/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-ipad-toolbar-ax-frame2.xcresult
device: iPad Air 11-inch (M4)
result: Passed
totalTestCount: 1
passedTests: 1
failedTests: 0
skippedTests: 0
expectedFailures: 0
observed library.add accessibility frame: 44 x 44
```

### Historical iPad failure — RESOLVED

```text
/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-portable-ui-ipad-20261120-020020.xcresult
device: iPad Air 11-inch (M4)
deviceId: C9CE77F1-89E8-4DF5-B101-871105BCED9B
result: Failed
totalTestCount: 7
passedTests: 6
failedTests: 1
skippedTests: 0
expectedFailures: 0
```

Historical finding: `PortableJourneyUITests.swift` expected width >= 44 and
observed `library.add` at a 36.0-point AX frame width. The iOS-only menu fix
above resolved it; the latest run and AX frame evidence pass. The failed bundle
is retained as history.

### Historical Mac UI failure — BLOCKED BY USER DECISION

```text
/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-portable-ui-mac-20261120-010944.xcresult
result: Failed
totalTestCount: 1 system failure, 0 app tests executed
failure: CalCoUITests-Runner encountered an error
  "The test runner failed to initialize for UI testing.
   (Underlying Error: Timed out while enabling automation mode.)"
```

This is a TCC/Automation initialization block, not a product test result. The
user chose to leave Mac UI blocked. Do not change OS security/privacy settings
and do not retry without a new explicit user decision. The failed bundle is
retained as history.

## Approved devices

| Device | Exact identity | Status |
| :--- | :--- | :--- |
| Native macOS | `platform=macOS,arch=arm64`, `My Mac` | production unit 751/751; UI blocked by user decision after runner initialization timeout |
| iPad Air 11-inch (M4) | `C9CE77F1-89E8-4DF5-B101-871105BCED9B` | portable UI 7/7 passed; AX fix verified |
| iPhone Duo | none | **unavailable; absent from Xcode 26.6; no substitute** |

`iPad Air 11-inch (M4)` is the only approved iPad. Do not use the 13-inch Air,
another iPad, or any iPhone as a Duo substitute. The exact Duo device type does
not exist in the installed runtime/toolchain.

## Final test matrix

| Gate | Device | Result |
| :--- | :--- | :--- |
| Mini UI | iPhone 13 mini `90964888-D59F-41EC-8DA2-419C829F3A71` | 26/26 passed, 0 failed, 0 skipped, 0 expected |
| Mini unit | same iPhone 13 mini | 751/751 passed, 0 failed, 0 skipped |
| iPad unit | iPad Air 11-inch (M4) `C9CE77F1-89E8-4DF5-B101-871105BCED9B` | 751/751 passed, 0 failed, 0 skipped |
| iPad portable UI | same iPad Air | 7/7 passed, 0 failed, 0 skipped, 0 expected |
| Mac production unit | `My Mac`, macOS 26.5.1 | 751/751 passed with pasteboard fix; actual run |
| Mac UI | `My Mac` | 0 app tests, runner initialization timeout; blocked by user decision |
| iPhone Duo | unavailable | not run, not substituted |

The iOS Library toolbar fix added no unit tests; the unit count remains 751.

## Latest acceptance artifacts

Base directory:
`/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/`

```text
calco-portable-ui-ipad-20261120-toolbar-fix-menu.xcresult   iPad UI 7/7 pass
calco-ipad-toolbar-ax-frame2.xcresult                      iPad AX 44x44 evidence
calco-mini-native-completion-toolbar-fix.xcresult          mini UI 26/26 pass
calco-unit-751-mini-toolbar-fix.xcresult                   mini unit 751/751 pass
calco-unit-751-ipad-toolbar-fix.xcresult                   iPad unit 751/751 pass
CalCoMacUnit-20261119-234644-production.xcresult           Mac production unit 751/751 pass
calco-portable-ui-mac-20261120-010944.xcresult             Mac UI 0 app tests; blocked history
calco-portable-ui-ipad-20261120-020020.xcresult            historical iPad 6/7; resolved
```

All listed bundles and their logs/attachments are retained. No broad cleanup
was performed.

## What this harness is

`frontend-ios/UITests/PortableJourneyUITests.swift` is the larger-device
acceptance suite. It is deliberately separate from the QA-owned, mini-only
`NativeCompletionUITests` suite.

- **Seven tests** execute on each destination.
- There is **no `XCTSkip` path** in the class. Missing fixture, failed launch,
  missing control, or a wrong window size is a failure.
- The suite never calls the mini 375×812 guard.
- The driver verifies the `.xcresult` summary: **executed == 7, passed == 7,
  failed == 0, skipped == 0, expected failures == 0**.
- A run with skipped tests is not a pass.
- The driver has no arbitrary suite/expected-count options. It accepts only
  `platform=macOS,arch=arm64` or the exact iPad UDID above, and always runs
  `CalCoUITests/PortableJourneyUITests` with expected count 7.
- Window assertions check both axes, positive intersection, full containment,
  and hittability for controls. Static-text leaves are checked for readable,
  fully visible frames. `scrollTo` returns only genuinely visible elements and
  can require full visibility for nutrient/report rows.

Journeys:

1. Diary navigation, selected historical date, Settings goal save, date retention.
2. Library custom-food create/edit/delete and ad-hoc Save food and log.
3. Meals seeded preview, notes edit/save, portion log, nutrient rows.
4. Nutrition report plus manual barcode leading-zero lookup and not-found review.
5. Assistant disabled gate plus enabled draft review and explicit save.
6. API-key create, one-time secret reveal/copy, and revoke.
7. Layout: narrow Mac window keyboard/editor containment, or iPad Air
   landscape/portrait expansion and 44-point touch targets.

Every journey asserts the fixture account-binding counters:
`bound_request_count > 0` and `unbound_protected_request_count == 0`.

## Fixture lifecycle

`frontend-ios/UITests/PortableQAMockServer.py` is a bounded launcher, not a fork
of the QA API fixture. It imports the current QA-owned
`NativeCompletionQAMockServer.py` (`FixtureState` and `Handler`) and preserves:

- fake credentials `native-qa` / `native-qa`;
- fixed profile UUID `22222222-2222-4222-8222-222222222222`;
- distinct session identity and profile IDs;
- `X-CalCo-Account-ID` binding semantics;
- capabilities v2 and all AI/Meals/custom-food/API-key routes owned by QA.

Only lifecycle behavior is added: loopback-only binding, port 0, a live
`GET /__qa/health` check before the ready marker, bounded maximum lifetime,
optional idle bound, and SIGINT/SIGTERM shutdown. The health check requires the
actual `native-completion-qa` marker, fixed profile UUID, `X-CalCo-Account-ID`,
and distinct identity/profile UUIDs. The driver repeats the live health check
and validates the reset summary in the test process. A mismatch is a failure.

The driver does **not** rely on shell environment forwarding. It runs
`build-for-testing`, copies the generated xctestrun into a private `0700`
directory, injects `CALCO_PORTABLE_UI_BASE_URL` only into
`CalCoUITests.EnvironmentVariables`, then runs `test-without-building` with
`-xctestrun`. The app under test receives the URL through the XCTest launch
environment. It does **not** call `serve_forever()` and is terminated/reaped in
`finally`. No server survives the run.

## Runtime command

These commands document the portable harness only; no run is part of this docs
update. Do not rerun Mac UI while it remains blocked by the user's decision.

The driver refuses to overwrite a result bundle and performs no deletions.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Native Mac
python3 frontend-ios/scripts/run_portable_ui.py \
  --destination 'platform=macOS,arch=arm64' \
  --derived-data "${TMPDIR%/}/calco-portable-ui-mac" \
  --result-bundle "${TMPDIR%/}/calco-portable-ui-mac.xcresult"

# iPad Air 11-inch (M4) — run only after the Mac run and after global focus release
python3 frontend-ios/scripts/run_portable_ui.py \
  --destination 'platform=iOS Simulator,id=C9CE77F1-89E8-4DF5-B101-871105BCED9B' \
  --derived-data "${TMPDIR%/}/calco-portable-ui-ipad" \
  --result-bundle "${TMPDIR%/}/calco-portable-ui-ipad.xcresult"
```

The driver uses a cleaned Apple-tool environment, hard build/test timeouts, a
private xctestrun, and the dynamic fixture URL. It leaves the Xcode logs next to
the result bundle, the private xctestrun, ready marker, and fixture log in a
`0700` run directory.

Contract checks are two separate commands. The QA fixture contract test is a
standalone script and is **not** discovered by the `scripts` pattern:

```bash
# QA-owned fixture contract (AI, Meals CRUD, account binding, capabilities)
python3 frontend-ios/UITests/NativeCompletionQAMockServerTests.py

# Portable driver/source contracts (not the QA fixture suite)
python3 -m unittest discover -s frontend-ios/scripts -p 'test_*.py' -v
```

Current faithful counts on this source: **10/10 fixture contract cases + 40/40
portable contract cases = 50/50 combined**. The portable cases cover exact
destination/suite/count rejection, real plist runner-env injection, loopback
proxy bypass, health marker/profile/header/identity drift, skip/partial counts,
and the seven-test/no-skip Swift source contract. No new portable/static UI test
was added for the toolbar fix.

## Mac UI permission risk

Native XCUITest requires macOS Accessibility/Automation permission for the test
runner. The actual run was blocked before test execution with:

```text
The test runner failed to initialize for UI testing.
(Underlying Error: Timed out while enabling automation mode.)
```

The user explicitly chose to leave Mac UI blocked. Do **not** change OS
security/preferences/TCC or retry unless a new user decision authorizes it. The
Mac production unit result remains valid; Mac UI is not accepted.

Other Mac caveats:

- The app must remain native macOS, not Mac Catalyst.
- `XCUIDevice.shared.orientation` is iOS-only. Existing UI tests now guard it
  with `#if os(iOS)`; the portable suite also guards rotation.
- Live credentialed E2E remains iOS Simulator-only because
  `CalCoE2E.supportsSecurePasswordEntry` is false on macOS. This portable suite
  uses only the nonsecret fake fixture credentials against the loopback mock.

## Source guards

Permitted orientation guards were added to:

- `frontend-ios/UITests/SettingsUITests.swift`
- `frontend-ios/UITests/LibraryRouteStabilityUITests.swift`
- `frontend-ios/UITests/MealsPreviewInteractionUITests.swift`

The QA-owned `NativeCompletionUITests.swift` is not edited here; its current
source is checked for orientation guards before Mac UI compilation. The mini
suite and its fixed 375×812 guard remain unchanged.

`MealsPreviewInteractionUITests.swift` also needed one iOS-only guard around
`tap(withNumberOfTaps:numberOfTouches:)`, which is unavailable on macOS. The iOS
double-tap behavior is unchanged; macOS compilation uses a select-all + type
path. This is the only non-orientation platform guard added.

## Decisions and outcomes

1. **Mac UI — closed by user decision.** Leave the runner blocked. No
   Accessibility/Automation/TCC change and no retry. Mac production unit is
   verified; Mac UI is not accepted.
2. **iPad product finding — resolved.** The iOS Library Add control now uses a
   native menu with a 44-point fixed frame and full hit shape. The latest
   portable UI run passed 7/7 and the AX frame artifact confirms 44 x 44. The
   Mac branch was unchanged.
3. **iPhone Duo — unavailable.** The exact device/type is absent from Xcode
   26.6; no substitute is authorized.

## Coordination and evidence rules

- iPad portable UI is complete; do not rerun it without a new parent request.
- Mac UI remains blocked by user decision; do not retry or change permissions.
- Keep derived data and result bundles; no broad cleanup.
- A 751/751 unit pass is not device UI acceptance.
- The portable harness itself contains no production feature edits; the iOS
  Library Add fix is recorded above as a product change outside the harness.
