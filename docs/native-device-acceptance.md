# Native device acceptance — Mac and iPad Air

Status: **Current rollback validation PASS: native unit 601/601 on exact
iPhone 13 mini, native Mac arm64 (`My Mac`), and iPad Air 11-inch (M4); iPad
portable UI 7/7; mini UI 24/24. Mac UI remains blocked by user decision;
iPhone Duo remains unavailable.** The old 751/26 results are retained as
historical pre-rollback evidence, not current verification.

- Native unit: **601/601 passed, 0 failures, 0 skips, 0 expected** on the exact
  iPhone 13 mini, native Mac arm64 (`My Mac`), and iPad Air 11-inch (M4).
- iPad Air 11-inch (M4): **7/7 passed, 0 failed, 0 skipped, 0 expected failures**
  in the current post-rollback portable run. The prior Library 44-point finding
  remains resolved.
- iPhone 13 mini UI: **24/24 passed, 0 failed, 0 skips, 0 expected** in the
  current QA-owned mini gate.
- Mac UI executed **0 app tests** and failed runner initialization with `Timed
  out while enabling automation mode`. The user explicitly chose to leave Mac
  UI blocked; no permission change, runtime Mac permission work, or retry is
  planned. This is one system/runner failure, not one failed product test.
- iPhone Duo: exact device/type is absent from Xcode 26.6; unavailable and not
  substituted.
- Current backend: **330 unit tests green with 0 failures, 4 existing ignored
  baseline tests visible, 62 integration tests green with 0 failures** at the
  exact `0ad3` baseline including migrations. The operation migrations are
  removed and confirmed unapplied; no DB schema, drop, or migration-history
  change was made.
- Current ordinary 503 retry: two explicit user attempts produced one log after
  the user pressed retry. No capability endpoint was called and no
  account-binding header was sent; the mock rejects `X-CalCo-Account-ID` with
  `400`, and the runtime checks passed with that rejection in place.
- Current Python helpers: **11/11 mock, 11/11 driver, 29/29 dev helper tests**.

Current validation artifacts, base
`/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/`:

- Mini unit: `calco-core-validation/Mini601/Mini601.xcresult`
- Mac unit: `calco-core-validation/Mac-601.xcresult`
- iPad unit: `calco-core-validation/iPadAir11-601.xcresult`
- Mini UI: `calco-no-replay-mini-20261120-183644/mini-24-final2.xcresult`
- iPad portable UI:
  `calco-no-replay-portable-20261120-200255/portable-7-final2.xcresult`

The earlier 751/751 native unit, 26/26 mini UI, and old portable 7/7 artifacts
are retained only as pre-rollback history.

## Current runtime record — 2026-11-20

### Current iPad acceptance — PASS

```text
/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-no-replay-portable-20261120-200255/portable-7-final2.xcresult
device: iPad Air 11-inch (M4)
deviceId: C9CE77F1-89E8-4DF5-B101-871105BCED9B
result: Passed
totalTestCount: 7
passedTests: 7
failedTests: 0
skippedTests: 0
expectedFailures: 0
```

The current portable fixture uses the normal cookie session, has no capability
endpoint, and rejects `X-CalCo-Account-ID` with HTTP `400`. The current
portable journeys did not send that header and passed.

## Historical runtime record — 2026-11-20 (pre-rollback)

### Historical iPad acceptance — PASS

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
above resolved it; the historical run and AX frame evidence passed. The failed
bundle is retained as history.

### Historical Mac UI failure artifact — block remains current

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

| Device | Exact identity | Current status |
| :--- | :--- | :--- |
| Native macOS | `platform=macOS,arch=arm64`, `My Mac` | unit 601/601; UI blocked by user decision after runner initialization timeout |
| iPad Air 11-inch (M4) | `C9CE77F1-89E8-4DF5-B101-871105BCED9B` | unit 601/601; portable UI 7/7 passed |
| iPhone 13 mini | `90964888-D59F-41EC-8DA2-419C829F3A71` | unit 601/601; mini UI 24/24 passed |
| iPhone Duo | none | **unavailable; absent from Xcode 26.6; no substitute** |

`iPad Air 11-inch (M4)` is the only approved iPad. Do not use the 13-inch Air,
another iPad, or any iPhone as a Duo substitute. The exact Duo device type does
not exist in the installed runtime/toolchain.

## Current test matrix

| Gate | Device | Current result |
| :--- | :--- | :--- |
| Mini unit | iPhone 13 mini `90964888-D59F-41EC-8DA2-419C829F3A71` | 601/601 passed, 0 failed, 0 skipped, 0 expected |
| Mac production unit | `My Mac`, native arm64 | 601/601 passed, 0 failed, 0 skipped, 0 expected |
| iPad unit | iPad Air 11-inch (M4) `C9CE77F1-89E8-4DF5-B101-871105BCED9B` | 601/601 passed, 0 failed, 0 skipped, 0 expected |
| Mini UI | same iPhone 13 mini | 24/24 passed, 0 failed, 0 skipped, 0 expected |
| iPad portable UI | same iPad Air | 7/7 passed, 0 failed, 0 skipped, 0 expected |
| Mac UI | `My Mac` | 0 app tests, runner initialization timeout; blocked by user decision |
| iPhone Duo | unavailable | not run, not substituted |

## Historical test matrix (pre-rollback)

None of these results is current rollback verification.

| Gate | Device | Historical result |
| :--- | :--- | :--- |
| Mini UI | iPhone 13 mini `90964888-D59F-41EC-8DA2-419C829F3A71` | 26/26 passed, 0 failed, 0 skipped, 0 expected |
| Mini unit | same iPhone 13 mini | 751/751 passed, 0 failed, 0 skipped |
| iPad unit | iPad Air 11-inch (M4) `C9CE77F1-89E8-4DF5-B101-871105BCED9B` | 751/751 passed, 0 failed, 0 skipped |
| iPad portable UI | same iPad Air | 7/7 passed, 0 failed, 0 skipped, 0 expected |
| Mac production unit | `My Mac`, macOS 26.5.1 | 751/751 passed with pasteboard fix; actual run |
| Mac UI | `My Mac` | 0 app tests, runner initialization timeout; blocked by user decision |
| iPhone Duo | unavailable | not run, not substituted |

The iOS Library toolbar fix added no unit tests; the historical unit count for
that pre-rollback build remained 751. Current unit is 601 after rollback test
removals; the old 751 count is not current.

## Historical acceptance artifacts (pre-rollback)

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

All listed bundles and their logs/attachments are retained as pre-rollback
history. No broad cleanup was performed. They are not current rollback
validation.

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

The current portable journeys use the normal cookie session and do not send an
account-binding header. The mock rejects `X-CalCo-Account-ID` with HTTP `400`,
and the current run passed with that rejection in place. The historical
journeys asserted pre-decision account-binding counters; those are not current
requirements.

## Fixture lifecycle

`frontend-ios/UITests/PortableQAMockServer.py` is a bounded launcher, not a fork
of the QA API fixture. It imports the current QA-owned
`NativeCompletionQAMockServer.py` (`FixtureState` and `Handler`) and preserves:

- fake credentials `native-qa` / `native-qa`;
- normal session/identity fixture data;
- the current AI/Meals/custom-food/API-key routes owned by QA.

Only lifecycle behavior is added: loopback-only binding, port 0, a live
`GET /__qa/health` check before the ready marker, bounded maximum lifetime,
optional idle bound, and SIGINT/SIGTERM shutdown. The current health check does
not require profile/account-binding fields; the fixture rejects
`X-CalCo-Account-ID` with `400`. The driver repeats the live health check and
validates the reset summary in the test process. A mismatch is a failure.

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
# QA-owned fixture contract (AI, Meals CRUD, and normal session routes)
python3 frontend-ios/UITests/NativeCompletionQAMockServerTests.py

# Portable driver/source contracts (not the QA fixture suite)
python3 -m unittest discover -s frontend-ios/scripts -p 'test_*.py' -v
```

Current helper counts: **11/11 mock, 11/11 driver, and 29/29 dev helper tests
passed**. The current portable cases cover exact destination/suite/count
rejection, real plist runner-env injection, loopback proxy bypass, health marker
drift, skip/partial counts, and the seven-test/no-skip Swift source contract.
The old 10/10 fixture + 40/40 portable counts belong to the historical
pre-rollback record.

## Mac UI permission risk

Native XCUITest requires macOS Accessibility/Automation permission for the test
runner. The actual run was blocked before test execution with:

```text
The test runner failed to initialize for UI testing.
(Underlying Error: Timed out while enabling automation mode.)
```

The user explicitly chose to leave Mac UI blocked. Do **not** change OS
security/preferences/TCC, perform runtime Mac permission work, or retry unless a
new user decision authorizes it. The Mac production unit is current at 601/601;
Mac UI is not accepted.

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
   Accessibility/Automation/TCC change, runtime permission work, or retry. Mac
   production unit is current at 601/601; Mac UI is not accepted.
2. **iPad product finding — resolved.** The iOS Library Add control uses a
   native menu with a 44-point fixed frame and full hit shape. The current
   portable UI run passed 7/7, and the AX frame artifact confirms 44 x 44. The
   Mac branch is unchanged.
3. **iPhone Duo — unavailable.** The exact device/type is absent from Xcode
   26.6; no substitute is authorized.

## Coordination and evidence rules

- Current iPad portable UI validation is complete at 7/7; do not rerun it
  without a new parent request.
- Mac UI remains blocked by user decision; do not retry, change permissions, or
  perform runtime Mac permission work.
- Keep derived data and result bundles; no broad cleanup.
- The current 601/601 unit pass is not device UI acceptance, and the historical
  751/751 pass is not current.
- The portable harness itself contains no production feature edits; the iOS
  Library Add fix is recorded above as a product change outside the harness.
