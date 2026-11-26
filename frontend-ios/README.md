# CalCo native client (`frontend-ios`)

A native SwiftUI client for CalCo, targeting **iOS 26, iPadOS 26 and macOS 26**.
It uses Apple frameworks plus Swift Package dependencies pinned in the Xcode
project. `swift-composable-architecture` **1.26.2** (exact) is the sole
architecture dependency choice, resolved through its `Package@swift-6.1.swift`
manifest variant for compatibility with the installed Xcode 26.6 / Swift 6.3.3
toolchain. Because app/test code directly references generated symbols from TCA
transitives already in the same resolved graph, the project also explicitly
declares and links `swift-dependencies` **1.17.2** (exact, product
`Dependencies`) and `swift-case-paths` **1.10.0** (exact, product `CasePaths`);
no unrelated library is added. Resolution is recorded in
`CalCo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Already-resolved `PerceptionCore` 2.0.12 is explicitly linked for app/test
generated-symbol references; `Clocks` 1.1.1 is linked only to the unit-test target.
UI uses native SwiftUI styling with Apple-default appearance and English-only
copy.

The TCA migration is partial: authentication and selected flows use TCA, while
the signed-in shell and several feature families remain legacy. Store-backed
Diary installation is QA-only (`CALCO_TEST` plus `CALCO_NATIVE_DIARY_QA=1`);
production Diary defaults to `.legacy`. See [TCA_MIGRATION.md](TCA_MIGRATION.md)
for accepted evidence and remaining work.

The normal-user workflows are implemented under the shared source directories:
diary and food logging, Library, Meals, Nutrition Details, reviewed AI
drafting, and personal API-key management. The sections below describe the
implemented paths and their ordinary data-safety behavior. Food-log creation is
a normal authenticated POST: an explicit retry may create a duplicate, the
duplicate is acceptable, and the user can delete it manually. See the accepted
[no-replay decision](../docs/decisions/2026-11-20-no-replay-protection.md) and
[Status and acceptance](#status-and-acceptance) before treating any result as a
release decision.

## Status and acceptance

Current status: **no-replay rollback validation passed.** The post-rollback
native suite passed on all three unit destinations and both available UI gates:
**601/601 unit tests** (0 failures, 0 skips, 0 expected) on the exact iPhone 13
mini, native Mac arm64 (`My Mac`), and iPad Air 11-inch (M4); **24/24 iPhone 13
mini UI**; and **7/7 iPad Air portable UI**. Mac UI remains blocked by explicit
user decision, and iPhone Duo is unavailable. The rollback removes only the new
replay, capability, account-binding-header, and ledger infrastructure; ordinary
native screens, validation, authentication, ownership, and atomicity remain.

- **Current backend:** **330 unit tests green, 0 failures; 4 existing ignored
  baseline tests visible; 62 integration tests green, 0 failures.** The backend
  matches the exact `0ad3` baseline including migrations. The withdrawn
  operation-migration source files `20261119000000` and `20261119000001` are
  deleted and were confirmed unapplied; they are removed, not pending rollout.
  No DB schema, drop, or migration-history change was made.
- **Current native unit:** **601/601 passed, 0 failures, 0 skips, 0 expected**
  on the exact iPhone 13 mini (`90964888-D59F-41EC-8DA2-419C829F3A71`), native
  Mac arm64 (`My Mac`), and iPad Air 11-inch (M4)
  (`C9CE77F1-89E8-4DF5-B101-871105BCED9B`).
- **Current iPhone 13 mini UI:** **24/24 passed, 0 failures, 0 skips, 0
  expected** at 375 x 812 points.
- **Current iPad Air 11-inch (M4) portable UI:** **7/7 passed, 0 failures, 0
  skips, 0 expected.**
- **Current ordinary 503 retry:** two explicit user attempts produced exactly
  one log after the user pressed retry. No capability endpoint was called and no
  account-binding header was sent; the mock rejects `X-CalCo-Account-ID` with
  `400`, and the runtime checks passed with that rejection in place.
- **Current helper suites:** 11/11 Python mock, 11/11 driver, and 29/29 dev
  helper tests passed.
- **Historical pre-rollback results (not current):** the earlier **751/751**
  native unit result and **26/26** mini UI result are retained as historical
  artifacts. They predate the rollback and are not current verification.
- **Mac UI remains blocked by explicit user decision.** The runner executed
  **0 app tests** and failed initialization with a macOS automation timeout
  (`Timed out while enabling automation mode`); this is one system/runner
  failure, not one failed product test. No OS privacy/TCC setting was changed,
  no runtime Mac permission work is planned, and no retry is planned.
- **iPhone Duo is unavailable**: the exact device/type is absent from Xcode
  26.6 and no substitute was used.
- Camera/photo capture and image-based AI drafting remain deferred product
  decisions and are not exposed in the native UI.

`docs/native-completion-qa.md` owns the current mini QA record and retains the
old 26-test result as history. `docs/native-device-acceptance.md` owns the
current portable acceptance record and retains the old 751/26 artifacts as
history. No final Mac UI or Duo acceptance is claimed. Current and historical
result-bundle paths are listed in those two documents.

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
(iPhones for `dev-frontend-ios`, iPads for `dev-frontend-ipados`). Labels are
never silently mapped to another model. The exact iPhone Duo device/type is
absent from Xcode 26.6; it is unavailable and no substitute is allowed. The
iPad Air portable UI gate passed 7/7 in the current rollback validation, and
the mini UI gate passed 24/24. Mac UI remains blocked by explicit user
decision, so no Mac UI pass is claimed. To use a label that is not installed,
install the matching Xcode/runtime and point the recipes at it:

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

**Swift package macro trust (CLI):** TCA and transitive dependencies include
Swift macros. Command-line builds may require
`-skipMacroValidation` until macros are approved for the machine/Xcode
environment. Use it only with audited, pinned package versions (this repo pins
TCA 1.26.2 and explicitly declares/links already-resolved `Dependencies` 1.17.2
and `CasePaths` 1.10.0 for direct generated-symbol linkage; resolution is
recorded in the repository's `Package.resolved`); the normal
Xcode alternative is to approve the macros in the IDE prompt. Do not disable
macro validation for unpinned or unreviewed packages.

The `CalCo` scheme uses `Debug` for Run/Test. The shared `CalCo-E2E` scheme uses
the `Test` configuration (127.0.0.1:3002) for Run/Test. Device builds need a
signing team; set `DEVELOPMENT_TEAM` in Xcode or pass
`DEVELOPMENT_TEAM=XXXXXXXXXX` to `xcodebuild`. Simulator and macOS builds need
no team.

## Source layout and discovery

| Path | Owner | Contents |
| :--- | :--- | :--- |
| `App/CalCoApp.swift` | scaffold (reserved) | The only `@main` entry point |
| `App/` (other files) | app implementor | Navigation, feature sheets, session-scoped wiring |
| `API/`, `Data/`, `Store/`, `Features/` | shared feature implementation | Network, models, adapters, state, views |
| `Features/Library/` | feature implementation | Custom-food list/editor/detail, ad-hoc logging, save-and-log |
| `Features/Meals/` | feature implementation | Meal list/editor/detail/flow and portion logging |
| `Features/NutritionDetails/` | feature implementation | Selected-day nutrient report |
| `Features/Assistant/` | feature implementation | Server-gated, text-only reviewed AI drafting |
| `Features/AccountSettings/` | feature implementation | Personal API-key list/create/revoke and one-time secret flow |
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

## Implemented workflows

Browsing uses pages: root tabs have no Back/Close, Library lists and details
share a navigation stack, custom-food and meal editors are pushed Back/Save
pages, ingredient selection is a child page, API Keys is pushed from Settings,
AI creation and its review editor stay on the originating page stack, and the
nutrition report is pushed from Diary. Detail pages have trailing Edit
and a separate final destructive section. The log editor has one bottom Save;
Delete is in the form rather than beside Save.

Temporary tasks use sheets: food/meal logging has leading Cancel and one bottom
Log action; date selection and repeat review retain Cancel/Done or Cancel/Log;
API-key creation has Cancel and one Create action. Logging keeps its
originating search/page underneath.
Opening these destinations does not reset the selected diary date or meal slot.
Historical dates and retained logs remain available.

### Diary and fast logging

- Diary supports previous/next/calendar date navigation, goal and macro display,
  log opening/editing, and confirmed deletion. Disabling a meal slot hides its
  add action but keeps historical logs visible; selecting a historical date does
  not get reset by Settings or a feature sheet.
- Search exposes **All**, **History**, **Custom**, and **Barcode** modes. Empty
  All/History views show server-ranked recents for the selected date and slot;
  categories come from `/api/foods/categories`.
- Food detail prefills the last-used amount/unit without overwriting later user
  edits, with a visible fallback when the unit is unavailable.
- Recents provide quantity chips, one-tap quick-add, and multi-select batch
  review. Empty eligible diary slots offer **Log latest** with the server's
  30-day lookback and a review of the source date/items.
- Manual barcode lookup preserves leading zeroes and can open a matching food
  or push a custom-food creation page when no product is found.

### Library, Meals, and Nutrition Details

- **Library** lists, creates, edits, and deletes custom foods with validated
  per-100 g nutrients, explicit units, optional servings, and confirmations.
  Existing diary snapshots are not rewritten when a custom food changes.
- Library also provides one-off ad-hoc logging and **Save food and log**. Food
  creation and logging use ordinary POST requests. An uncertain outcome is
  reported to the user; a deliberate retry may create a duplicate food or log,
  which is acceptable and can be deleted manually.
- The iOS Library **Add** action is a native menu
  (`.menuStyle(.button)`, `.buttonStyle(.plain)`,
  `.frame(width: 44, height: 44)`, `.fixedSize()`, and
  `.contentShape(Rectangle())`). It keeps a 44 x 44 accessibility frame. The Mac
  branch is unchanged.
- **Meals** lists, creates, edits, and deletes meals with product-only
  components, quantities/units, notes, and total recipe quantity. Library meal
  screens are management-only: neither list quick-add nor detail logging is
  available. A deleted component produces a degraded list/detail; the user can
  repair the recipe or delete it with confirmation. Recipe edits do not rewrite
  existing log snapshots.
- **Nutrition Details** opens for the selected diary day and shows server
  nutrient totals, units, reference amounts, meaningful progress, coverage
  warnings, expandable guidance, and reference/source context. Unknown values
  remain distinct from zero, and the report is never derived from current food
  data.
- **AI food drafting** is enabled only when
  `/api/ai/food-assistant/status` reports the assistant as available. Drafting is
  text-only, supports custom-food and ad-hoc purposes, and always requires
  explicit review in a separate editor before any save or log. An accepted draft
  writes nothing by itself. Even if the server reports image support, the native
  UI exposes no image picker or image upload.
  **My Foods → Create with AI → review/edit** uses pushed pages, not sheets.
  Back from review preserves edited values and the conversation; leaving the
  AI task asks before discarding work. Save completes the entire task and
  refreshes the original food list, without opening another Library list.
- **Account Settings → API Keys** lists, creates, and revokes personal keys with
  supported read/read-write scopes, optional expiry, and an active-key limit.
  A new secret is shown once in memory, can be deliberately copied, and is
  never persisted, logged, or included in diagnostics. An uncertain create is
  reported and the list is refreshed instead of being retried automatically; no
  durable intent ledger is used.

Camera barcode scanning and image-based AI drafting are **not implemented** and
no camera/photo permission is requested. Manual barcode lookup and text AI
drafting are shipped. No camera, photo, assistant-image, admin, browser-theme, or
additional-language scope is implied by the current client.

## Data safety and ordinary retry behavior

### Account and selected-day boundaries

- Feature state is scoped to the signed-in account and session generation;
  stale responses or unauthorized results from an earlier session cannot
  publish into a newer session.
- Authentication and feature graphs use the normal signed-in identity and
  username. There is no strict profile-missing gate, no capability-v2 gate, and
  no `X-CalCo-Account-ID` account-binding header. Protected requests rely on
  the shared cookie session.
- The shared session authority owns the cookie session and session generation.
  Feature services are rebuilt for each signed-in session graph, so an earlier
  session's state cannot leak into a newer one.
- In-flight submissions carry ordinary account and session-generation context
  only to detect a session change. That context is local cancellation state and
  is not sent as an account-binding request header.

### Creation and manual retry

- Single, batch, ad-hoc, quick-add, repeat, and meal log creation are ordinary
  authenticated POSTs. New flows do not use capability negotiation, a durable
  operation journal, request fingerprints, tombstones, prepared-intent ledgers,
  or automatic replay.
- If a create is retried or submitted twice, a duplicate food log is
  acceptable. The user can see the duplicate and delete it manually. Retry is
  an explicit user action; the client does not silently replay an uncertain
  write.
- Ordinary validation, authentication, ownership, and atomic batch behavior
  remain. A failed batch must not leave partial writes, and errors are shown to
  the user.
- The preexisting baseline legacy single-food FoodDetail journal in
  `Store/LogSubmissionStore.swift` and the server's existing optional key
  behavior predate this rollback and remain outside it. The policy does not
  claim they were removed. `Store/LogSubmissionService.swift` is the ordinary
  direct transport for new submissions and is not a journal. No new flow should
  depend on the legacy journal or advertise automatic replay safety.
- There are no new request fingerprints except that baseline legacy path, and no
  generic durable catalog, meal, or API-key intent ledgers.
- The operation migrations are removed, not pending rollout. Any old instruction
  to apply `20261119000000` or `20261119000001` is historical and must not be
  followed; their source files are deleted, confirmed unapplied, and no schema
  or migration-history change was made.
- Log deletion is confirmed. Deleting a duplicate or unwanted log is the normal
  user-facing cleanup path; there is no permanent operation tombstone or
  key-reuse window.
- Historical API documentation that describes the abandoned idempotency-key or
  operation API is pre-decision documentation and does not override the
  [no-replay decision](../docs/decisions/2026-11-20-no-replay-protection.md).

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
the test host environment for E2E runs. Session cookies use the shared
`URLSession` cookie store; a newly created API-key secret exists only in memory
and is not written to source, config, defaults, files, logs, or diagnostics.
Never include a secret in screenshots, fixtures, or documentation. The override
does not relax Release ATS: a non-loopback HTTP host still needs a Debug/Test-only
exception in `Info-Debug.plist` / `Info-Test.plist`.

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

Keys are grouped under `app.*`, `auth.*`, `diary.*`, `foodDetail.*`,
`settings.*`, `search.*`, `submission.*`, `journal.*`, `library.*`, `meals.*`,
`nutrition.*`, `assistant.*`, and `apiKeys.*`, plus the app display name.
Search the catalog before adding a key rather than duplicating copy.

Several entries use format placeholders such as `%@` and `%lld`.
`nutrition.coverage.includedCount` uses English plural variations. Add plural
variations for any new count-based string instead of concatenating grammar in
Swift, and keep all user-visible copy in this single English catalog.

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
`diary.addFood.*`, `diary.summary.calories`, `diary.log.*`,
`diary.settings`, `settings.*` and `foodDetail.*`. It is wired into the shared
**`CalCo-E2E`** scheme only — the `CalCo` scheme is unchanged.

The app under test is always the isolated **`dev.calco.CalCo.Test`** bundle.
Its default backend is **`http://127.0.0.1:3002`**; a runner may inject
`CALCO_E2E_BASE_URL` to use another isolated stack. This override exists solely
for the user-approved isolated live E2E backend; it is not a general
remote-backend feature. The helper accepts only `localhost`, `127.0.0.1`, or
`::1` over http(s), with no user info, query, or fragment. A LAN or Internet
URL is rejected before the app launches, so credentials are never directed at
an arbitrary remote host. It never targets the `Debug` app or the development
backend on `localhost:3001`.

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
# Optional: another loopback-only isolated stack. Defaults to 3002 when absent.
# data["CalCoUITests"]["EnvironmentVariables"]["CALCO_E2E_BASE_URL"] = \
#     "http://127.0.0.1:3902"
with open(xctestrun, "wb") as handle:
    plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
PY
```

`CALCO_E2E_BASE_URL` belongs only in the `CalCoUITests` runner environment.
The test helper validates it before launching the app and passes it to the app
as `CALCO_API_BASE_URL`. Never put credentials in the URL, query, or a scheme.

Run the credentialed tests with that private xctestrun:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -xctestrun "$PRIVATE_RUN/run.xctestrun" \
  -destination 'platform=iOS Simulator,name=iPhone 17e' \
  -only-testing:CalCoUITests/CalCoSmokeUITests/testSignInWhenCredentialsAvailable \
  -only-testing:CalCoUITests/VerticalSliceUITests/testLogE2ETestFoodFromSelectedDayDiary \
  -only-testing:CalCoUITests/SettingsUITests/testHistoricalDateRetentionGoalAndSlotSettings \
  -resultBundlePath "$PRIVATE_RUN/result.xcresult" \
  test-without-building 2>&1 | tee "$PRIVATE_RUN/run.log"
```

`SettingsUITests` expects an isolated fixture with a historical diary date and
a separate today goal. The checked-in defaults use the seed's 2026-11-17
historical date, 2026-11-19 today, baseline 2140/160/240/60, and a disabled
late-night slot that retains a historical log. A regenerated fixture can set
these nonsecret runner environment values:

```text
CALCO_E2E_FIXTURE_TODAY=YYYY-MM-DD
CALCO_E2E_FIXTURE_HISTORICAL_DATE=YYYY-MM-DD
CALCO_E2E_FIXTURE_BREAKFAST_LOG_ID=<uuid>
CALCO_E2E_FIXTURE_LATE_NIGHT_LOG_ID=<uuid>
CALCO_E2E_FIXTURE_BASELINE_GOAL=2140,160,240,60
CALCO_E2E_FIXTURE_EDITED_GOAL=2180,160,250,60
CALCO_E2E_FIXTURE_HISTORICAL_CALORIES=1629
CALCO_E2E_FIXTURE_HISTORICAL_GOAL=2100
```

`CALCO_E2E_FIXTURE_TODAY` must match the app's device-local today; otherwise
the computed fixture-day navigation and today-goal assertions intentionally
fail. If the date variables are omitted, the checked-in defaults are accepted
only on 2026-11-19; the test fails its prerequisite with a reseed/config
message on another date.

The test asserts the disabled late-night historical log is already visible
under native retained-log semantics. It best-effort restores the initially
read goal and dinner-slot state from `tearDown`, including after an assertion
aborts the journey. If cleanup cannot run because the app or session is gone,
reset the isolated fixture before rerunning.

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
