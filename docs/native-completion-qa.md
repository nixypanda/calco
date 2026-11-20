# Native completion QA — iPhone 13 mini

Status: **PASS for the current 24-test mini UI rollback gate.** The
post-rollback suite passed 24/24 on the exact booted iPhone 13 mini with zero
failures, zero skips, and zero expected failures. Current native unit is
**601/601** on the exact mini, native Mac arm64, and iPad Air 11-inch (M4).
The old 26/26 result is retained below as historical pre-rollback evidence only,
not current verification. Current backend is **330 unit green with 0 failures,
4 existing ignored baseline tests, and 62 integration green with 0 failures**
at the exact `0ad3` baseline including migrations.

Date: 2026-11-20

## Current result

```text
Executed 24 tests, with 24 passed, 0 failed, 0 skipped, 0 expected failures
```

- Current result bundle:
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-no-replay-mini-20261120-183644/mini-24-final2.xcresult`
- Current native unit bundles under
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/`:
  `calco-core-validation/Mini601/Mini601.xcresult`,
  `calco-core-validation/Mac-601.xcresult`, and
  `calco-core-validation/iPadAir11-601.xcresult`.
- Current mini suite shape: 24 tests; the old replay/capability/account-binding
  requirements are removed. The fixed 375 x 812 `assertIPhone13Mini` guard
  remains.

## Current ordinary retry behavior

- The mini build uses the normal signed-in identity/username and shared cookie
  session. It does not call a capability endpoint and does not send an
  account-binding header.
- The mock rejects `X-CalCo-Account-ID` with HTTP `400`; the runtime checks
  passed with that rejection in place.
- The ordinary manual **503 retry** test made two explicit user attempts and
  produced exactly one log after the user pressed retry. This is not automatic
  replay: retry remains a user action, and duplicates from a genuinely repeated
  create are acceptable and manually deletable.
- Python helpers passed: **11/11 mock, 11/11 driver, 29/29 dev helper tests.**

## Historical pre-rollback result (not current)

```text
Executed 26 tests, with 26 passed, 0 failed, 0 skipped, 0 expected failures
```

- Historical result bundle:
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-mini-native-completion-toolbar-fix.xcresult`
  (after the iOS Library 44 x 44 Add-menu fix, before the no-replay rollback).
- Earlier retained result bundle:
  `/private/var/folders/ky/lktlhg4x5v11fg0jydm7fkrm0000gn/T/opencode/calco-native-qa-full-26-final.xcresult`
- Historical Xcode test-results summary: 26 total, 26 passed, 0 failed, 0
  skipped, 0 expected failures.
- Historical mock contract result was 10/10 at that time. This is not a current
  count.
- Historical suite shape: 26 `testMini...` methods; `XCTExpectFailure` was
  absent. The three `XCTSkip` paths were environmental guards for a missing
  mock, a wrong mock fixture marker, or a non-375 x 812-point window. None
  triggered in that run.
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

## Removed pre-decision binding checks

The historical run asserted a profile-based request account-binding header and
capability v2 requirements. Both were removed by the no-replay decision and are
not current behavior. The current native client uses the normal signed-in
identity/username and the shared cookie session, with no account-binding header;
the current mock rejects `X-CalCo-Account-ID` with `400` and the runtime checks
passed. Any binding or capability assertion retained in the historical result
bundle is historical only.

## Historical coverage detail (26-test pre-rollback run)

The test narratives and timings below belong to the retained historical 26-test
run, not the current 24-test run. They are kept as pre-rollback evidence.

### Enabled assistant coverage

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

The assistant-disabled gate was green in that historical run.

### Full meal lifecycle and repair coverage

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
- Logs the repaired meal once and deletes it with confirmation, with the
  journey's expected PUT/DELETE/log counts. The selected historical date remains
  held. Duplicate protection was a pre-decision check only, not a current
  requirement.

The mock returns the faithful `409 missing_components` contract for invalid
create/update/nutrient requests and degrades existing meals when a referenced
food disappears.

### Other historical verified journeys

- Login with the fixture password and a 375 x 812 window.
- Toolbar actions and the persistent feature bar: `diary.library`,
  `diary.meals`, `diary.nutrition` only.
- Diary log-row center tap and editor Save/Delete, including the iOS 26 popover
  dismissal path for delete confirmation.
- AX XXXL diary and Settings reachability, pending banner Review full width,
  44 x 44 dismiss, and inline retry after dismissing the banner. Any
  idempotent-replay assertion from the pre-rollback build is historical only and
  is not a current requirement.
- Settings goal save with a macro-consistent 2230 kcal target, recorded `PUT`,
  and historical-day goal retention at 800 / 2000.
- Library custom-food create/list/view/edit/delete and ad-hoc save-and-log with
  exact one-food/one-log counts and one canonical completion Done. The iOS
  Library Add menu is verified at a 44 x 44 accessibility frame.
- Meals preview with `ENERGY_KCAL`, `PROTEIN_G`, `CARBS_G`, `FAT_G`; meal log
  success and historical-date retention.
- API-key create/reveal/copy/revoke.
- Nutrition destination, calendar and macro mode, barcode leading zeros and
  not-found, quick-add/batch review, repeat-latest review, and search result
  center tap.

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

`NativeCompletionQAMockServer.py` is loopback-only and in-memory. The current
fixture serves normal auth/session, diary logs/goals/preferences, units, food
search/detail/barcode, recent/last-used/latest-slots, single/batch/ad-hoc logs,
custom-food CRUD, meals CRUD/nutrients, nutrition details, API-key
create/list/delete, and assistant status/draft. It has no capability endpoint
and rejects `X-CalCo-Account-ID` with `400`. The historical fixture also served
the old capability/account-binding checks; those are not current policy.
`POST /__qa/reset` resets the fixture; `GET /__qa/state` exposes counts and
mini-gate counters only. Current Python helper suites are 11/11 mock, 11/11
driver, and 29/29 dev helpers.

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

- This is a scoped simulator UI gate, not a live-backend test or
  production-data proof. The mock cannot prove live server behavior,
  migrations, or real account isolation.
- Current backend is 330 unit tests green with 0 failures, 4 existing ignored
  baseline tests visible, and 62 integration tests green with 0 failures at the
  exact `0ad3` baseline including migrations. The operation migrations are
  removed and confirmed unapplied; no DB schema or migration-history change was
  made.
- Current native unit is 601/601 on the exact mini, Mac, and iPad. This mini
  harness did not run Mac UI, iPad portable UI, or iPhone Duo; the portable
  record covers the current iPad 7/7 pass, the Mac UI block by user decision,
  and the unavailable Duo.
- AX checks focus on the current standard and accessibility XXXL mini paths;
  they are not a full accessibility audit.
- The native unit suite is not run by this QA harness. Current and historical
  unit results and artifact paths are recorded in `frontend-ios/README.md` and
  `docs/native-device-acceptance.md`.
