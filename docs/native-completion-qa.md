# Native completion QA — iPhone 13 mini

Status: **PASS for the scoped mini UI gate**. The final 26-test native UI suite
passed on the exact booted iPhone 13 mini with zero failures, zero skips, and
zero expected failures. This PASS covers the journeys listed below, not the
uncovered flows at the end of this document and not other device classes.

Date: 2026-11-20

## Final result

```text
Executed 26 tests, with 26 passed, 0 failed, 0 skipped, 0 expected failures
```

- Latest result bundle:
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-mini-native-completion-toolbar-fix.xcresult`
  (after the iOS Library 44 x 44 Add-menu fix).
- Earlier retained result bundle:
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-native-qa-full-26-final.xcresult`
- Xcode test-results summary: 26 total, 26 passed, 0 failed, 0 skipped,
  0 expected failures.
- Mock contract tests: 10/10 pass with
  `python3 frontend-ios/UITests/NativeCompletionQAMockServerTests.py`.
- Suite shape: 26 `testMini...` methods; `XCTExpectFailure` is absent. The only
  three `XCTSkip` paths are environmental guards for a missing mock, a wrong
  mock fixture marker, or a non-375 x 812-point window. None triggered in the
  final run.
- `NativeCompletionUITests` orientation assignments are wrapped in `#if os(iOS)`
  so the shared Mac UI-test target compiles without changing iOS behavior. The
  fixed 375 x 812 `assertIPhone13Mini` guard remains intact.

## Device and safety record

- Device: `CalCo Review 13 mini`, `iPhone 13 mini`,
  `90964888-D59F-41EC-8DA2-419C829F3A71`, 375 x 812 points, iOS 26.5.
- Toolchain: Xcode 26.6 (17F113), iOS 26.5 Simulator runtime 23F77.
- App under test: real isolated Test app `dev.calco.CalCo.Test`.
- Network: `NativeCompletionQAMockServer.py` on `http://127.0.0.1:3932`,
  in-memory only, fake credentials `native-qa` / `native-qa`.
- No live database, real user, real credential, or live API key was used. No
  real secret was written to source, logs, screenshots, or attachments.
- This mini QA harness used only the already-booted mini. Mac, iPad Air, and Duo
  runs are outside this harness; portable acceptance separately records the iPad
  Air pass and the Mac UI block. No other device was erased or shut down by this
  harness.
- Production files were read only for this QA record. No commit was made.

## Account binding under the final build

The fixture and representative journeys verify the strict production binding:

- Session `identity.id` and `profile.id` are distinct valid UUIDs; the stable
  profile UUID is `22222222-2222-4222-8222-222222222222`.
- Ready capabilities include
  `request_account_binding: "x-calco-account-id"` and version 2.
- Protected requests carrying `X-CalCo-Account-ID` are accepted only for the
  profile UUID. Wrong profile values return `401 session_account_changed`;
  malformed values return `400 invalid_account_header`.
- Login, session restore, and logout are exempt.
- The mock counts protected, bound, and unbound requests. Representative
  journeys assert at least one bound request and zero unbound protected
  requests; the mock does not ignore a supplied header.

## Enabled assistant coverage

`testMiniAssistantEnabledCustomDraftRequiresExplicitSave` passed in 42.505 s:

- Searches through the normal Search assistant entry with the fixture enabled.
- Sends the multipart conversation and receives a draft with the four required
  macros as decimal strings, a serving, and warnings.
- Accepts the draft into the Library custom-food editor and verifies the
  prefilled name, brand, macros, and that **no food or log POST happened** on
  acceptance.
- Refocuses and edits the Library form, explicitly saves, and observes exactly
  one custom-food POST and zero log POSTs.

`testMiniAssistantEnabledAdHocDraftRequiresReviewConfirm` passed in 55.135 s:

- Uses the ad-hoc assistant purpose and verifies the suggested `1 bowl (40 g)`
  log plus the four macro values.
- Accepts into the ad-hoc editor; verifies the suggested quantity/unit and the
  scaled 40 g nutrients (152 kcal for the 380 kcal/100 g draft).
- Confirms that acceptance alone writes nothing. The explicit Review alert then
  `Log food` writes exactly one 1 bowl ad-hoc log and no food.

The existing assistant-disabled gate remains green.

## Full meal lifecycle and repair coverage

`testMiniMealsCreateEditDeleteAndMissingRepair` passed in 71.474 s:

- Creates a meal through the real component picker with name, notes, total
  150 g, product selection, 100 g quantity, and gram unit.
- Opens detail, verifies notes/total and the server-backed preview macro rows,
  and counts exactly one meal POST.
- Removes `qa-apple` from the fixture catalog, reopens Meals, and verifies the
  degraded list warning and missing-ingredient detail.
- Confirms a degraded meal exposes no false preview and no Log action, and
  issues no log POST.
- Edits the degraded meal, removes the broken component, replaces it with
  `qa-pear`, and saves. The detail returns to a safe, loggable preview.
- Logs the repaired meal exactly once, deletes it with confirmation, and
  verifies one meal PUT, one meal DELETE, one log POST, and no duplicate
  operations. The selected historical date remains held.

The mock returns the faithful `409 missing_components` contract for invalid
create/update/nutrient requests and degrades existing meals when a referenced
food disappears.

## Other verified journeys

- Login with the fixture password and a 375 x 812 window.
- Toolbar actions and the persistent feature bar: `diary.library`,
  `diary.meals`, `diary.nutrition` only.
- Diary log-row center tap and editor Save/Delete, including the iOS 26 popover
  dismissal path for delete confirmation.
- AX XXXL diary and Settings reachability, pending banner Review full width,
  44 x 44 dismiss, inline retry after dismissing the banner, exactly one
  idempotent replay and one new log.
- Settings goal save with a macro-consistent 2230 kcal target, recorded `PUT`,
  and historical-day goal retention at 800 / 2000.
- Library custom-food create/list/view/edit/delete and ad-hoc save-and-log with
  exact one-food/one-log counts and one canonical completion Done. The iOS
  Library Add menu is verified at a 44 x 44 accessibility frame.
- Meals preview with `ENERGY_KCAL`, `PROTEIN_G`, `CARBS_G`, `FAT_G`; meal log
  success and historical-date retention.
- API-key create/reveal/copy/revoke.
- Nutrition destination, calendar and macro mode, barcode leading zeros and
  not-found, quick-add/batch without double POST, repeat-latest review, and
  search result center tap.

## Exact mini commands

Start the deterministic fixture:

```bash
python3 frontend-ios/UITests/NativeCompletionQAMockServer.py --port 3932
```

Build and run on the booted mini. Use a cleaned environment; the Nix shell
exports an incompatible `DEVELOPER_DIR`/`SDKROOT`/`LD`/`CC`/`CXX`.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVICE=90964888-D59F-41EC-8DA2-419C829F3A71
DERIVED="${TMPDIR%/}/calco-native-qa-derived"
RESULT="${TMPDIR%/}/calco-native-qa.xcresult"

env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LOGNAME="$LOGNAME" \
  SHELL=/bin/sh TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  DEVELOPER_DIR="$DEVELOPER_DIR" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project frontend-ios/CalCo.xcodeproj \
  -scheme CalCo-E2E -configuration Test \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  build-for-testing

env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LOGNAME="$LOGNAME" \
  SHELL=/bin/sh TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  DEVELOPER_DIR="$DEVELOPER_DIR" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project frontend-ios/CalCo.xcodeproj \
  -scheme CalCo-E2E -configuration Test \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -only-testing:CalCoUITests/NativeCompletionUITests \
  -resultBundlePath "$RESULT" \
  test-without-building
```

## Fixture contract

`NativeCompletionQAMockServer.py` is loopback-only and in-memory. It serves
auth/session, capabilities, diary logs/goals/preferences, units, food
search/detail/barcode, recent/last-used/latest-slots, single/batch/ad-hoc logs,
custom-food CRUD, meals CRUD/nutrients, nutrition details, API-key
create/list/delete, and assistant status/draft. `POST /__qa/reset` resets the
fixture; `GET /__qa/state` exposes counts and mini-gate counters only.

The fixture reset accepts `assistant_enabled` to switch the assistant gate while
keeping the disabled-gate test deterministic. The multipart assistant route
accepts the production purposes `custom_food` and `ad_hoc_log` and returns the
exact draft DTO: four required macros as decimal strings, servings, warnings,
and a suggested log only for the ad-hoc purpose.

Meal routes implement create/list/detail/update/delete, product-backed component
nutrition, `409 missing_components` validation, degraded list/detail DTOs, and
repair. `POST /__qa/remove-food` is a test-only fixture control used to simulate
a catalog food disappearing; it is not an app route. Custom-food create/update
preserves submitted per-100 g nutrients and servings, and log responses preserve
the request item identity/quantity/unit so native response validation accepts
them.

## Remaining uncovered flows and limitations

- This is a scoped simulator UI gate, not a live-backend or production-data
  test. The mock cannot prove live server behavior, migrations, or real account
  isolation.
- This mini harness did not run Mac, iPad Air, or iPhone Duo. Portable
  acceptance separately records the iPad Air 7/7 pass, the Mac UI block by user
  decision, and the unavailable Duo.
- AX checks focus on the required standard and accessibility XXXL mini paths;
  they are not a full accessibility audit.
- The native unit suite is not run by this QA harness. Final unit results and
  artifact paths are recorded in `frontend-ios/README.md` and
  `docs/native-device-acceptance.md`.
