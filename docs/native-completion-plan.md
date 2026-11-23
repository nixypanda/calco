# Native client completion plan

Status: **no-replay rollback verified; 601/601 native unit on mini, Mac, and
iPad; 24/24 mini UI; 7/7 iPad portable UI; Mac UI blocked by user decision;
iPhone Duo unavailable** (updated 2026-11-20). The old 751/26 results are
historical pre-rollback artifacts, not current verification. The project is not
fully accepted for Mac UI or Duo. See [Implementation status](#implementation-status),
`docs/native-completion-qa.md`, `docs/native-device-acceptance.md`, and the
accepted [no-replay decision](decisions/2026-11-20-no-replay-protection.md).

## Scope and baseline

Complete the normal-user workflows in `frontend-ios` for iOS 26, iPadOS 26,
and native macOS 26. Keep Apple-default appearance, English-only strings, and
Apple frameworks only. Do not add admin tools, browser theme controls, or Hindi
localization as incidental parity work.

Implemented and current-verified normal-user scope (the earlier 751/26 results
remain historical only):

- Diary navigation, log editing/deletion, goals, enabled slots, historical
  retention, and selected-date preservation across feature sheets.
- Ordinary account-scoped logging with session-generation-bound UI context for
  single, batch, ad-hoc, and meal submissions, including quick-add, repeat
  latest, and last-used prefill. Creates are normal POSTs; an explicit retry may
  create a duplicate, which is acceptable and can be deleted manually.
- Search scopes, recents, categories, manual barcode lookup, and batch review.
- Library custom-food management, ad-hoc logging, and save-food-then-log.
- Meals list/create/detail/edit/delete and portion logging.
- Per-day Nutrition Details with coverage, references, and guidance.
- Server-gated text AI drafting with explicit reviewed-draft handoff.
- Account Settings personal API-key list/create/revoke.

Manual barcode lookup and text AI drafting are shipped. Camera barcode scanning
and image-based AI drafting are not implemented and are not exposed in the
native UI.

## Implementation status

Current rollback validation is complete for the available unit and UI gates.

| Milestone | Current status |
| :--- | :--- |
| 0. Baseline and shared contracts | Verified; 601 unit tests passed; mini UI 24/24 |
| 1. Ordinary logging paths | No-replay policy applied; ordinary POST logging verified |
| 2. Diary and fast food logging | Verified on mini and iPad |
| 3. Nutrition details | Verified on mini and iPad |
| 4. Library and ad-hoc logging | Verified with ordinary create/retry paths |
| 5. Meals and logging integration | Verified, including degraded missing-component repair/delete |
| 6. Barcode and assistant drafting | Verified for manual barcode and text AI; camera and image drafting deferred |
| 7. Account settings API keys | Verified |
| Final interactive/device acceptance | Native unit 601/601; mini UI 24/24; iPad portable UI 7/7; Mac UI blocked by user decision; Duo unavailable |

Current native unit baseline: **601 test methods; 601 passed, 0 failures, 0
skips, 0 expected** on the exact iPhone 13 mini
(`90964888-D59F-41EC-8DA2-419C829F3A71`), native Mac arm64 (`My Mac`), and iPad
Air 11-inch (M4) (`C9CE77F1-89E8-4DF5-B101-871105BCED9B`).

Current mini UI gate: **24/24 passed, 0 failed, 0 skipped, 0 expected failures**
on the exact iPhone 13 mini at 375 x 812 points. Current iPad Air portable UI
gate: **7/7 passed, 0 failed, 0 skipped, 0 expected failures** on the exact UDID.
The current ordinary **503 retry** check used two explicit user attempts to
produce exactly one log after the user pressed retry. No capability endpoint was
called and no account-binding header was sent; the mock rejects
`X-CalCo-Account-ID` with `400`, and the runtime checks passed with that
rejection in place. Current Python helper suites are **11/11 mock, 11/11 driver,
and 29/29 dev helper tests**.

The earlier **751/751** native unit result and **26/26** mini UI result are
retained only as historical pre-rollback evidence. They are not current
verification. Old iPad portable 7/7 artifacts are likewise historical; the
current iPad 7/7 run has its own artifact.

Mac UI is still not accepted: the runner executed **0 app tests** and failed
initialization with `Timed out while enabling automation mode`. The user chose
to leave Mac UI blocked; no permission change, runtime Mac permission work, or
retry is planned. This is a runner/system initialization failure, not a product
assertion failure. The exact iPhone Duo device/type is absent from Xcode 26.6
and no substitute was used.

The current backend is at the exact `0ad3` baseline including migrations:
**330 unit tests green, 0 failures; 4 existing ignored baseline tests visible;
62 integration tests green, 0 failures.** The operation-migration source files
`20261119000000` and `20261119000001` are removed, deleted, and confirmed
unapplied. They are not a pending rollout, and old instructions to apply them
are historical and must not be followed. No DB schema, drop, or
migration-history change was made.

Current and historical acceptance result bundles and their approved temporary
base paths are listed in `docs/native-device-acceptance.md`; the current and
historical mini QA bundles are listed in `docs/native-completion-qa.md`.

The milestones below remain the normal-feature acceptance and regression
checklist. Current rollback validation passed for mini UI, iPad portable UI, and
all three unit destinations; Mac UI remains blocked by the user decision and
iPhone Duo is unavailable.

## Delivery order

This delivery order is retained for the normal features. It is not a
requirement to rebuild replay infrastructure. The imperative bullets describe
completed or intended normal-feature criteria, and any historical
replay/duplicate-safety wording is replaced by the policy: duplicates are
acceptable and are deleted manually. Keep future fixes small and independently
reviewable; do not combine unrelated work into one change.

### 0. Verify the baseline and define shared contracts

- Run native unit tests and build iOS Simulator and native macOS destinations.
- Verify edit/delete, calendar, macro toggle, goal changes, enabled slots, and
  returning to a historical diary date; fix failures before extending them.
- Compare the web's actual request/response models with backend handlers for
  every new workflow. Record decimal, unit, null, error, and ownership semantics.
- Extend the existing navigation model for Library, Meals, Nutrition Details,
  and Account Settings without resetting diary date or meal-slot context.
- Keep networking in `API/`, DTOs in `Data/`, adapters in `Store/`, and feature
  state/views in `Features/`. Reuse the log form rather than forking it.

Exit: a tested baseline, destination inventory, and explicit API contract tests.

### 1. Keep logging on ordinary request paths

This is a policy boundary, not a replay-infrastructure milestone. New single,
batch, ad-hoc, quick-add, repeat, and meal creates use plain authenticated POSTs.

- Do not add a durable operation journal, request fingerprints, tombstones,
  capability negotiation, prepared-intent ledgers, request-account-binding
  headers, or automatic replay for these flows.
- An explicit user retry may create a duplicate. The duplicate is acceptable;
  the user can see it and delete it manually.
- Ordinary validation, authentication, ownership, and atomic batch behavior
  remain. A failed batch must not leave partial writes, and errors are shown to
  the user instead of being retried automatically.
- The preexisting single-food FoodDetail journal is retained only as baseline
  legacy code. It is not a requirement for new logging paths and is not a
  promise of retry safety for them.

Exit: normal logging works through ordinary requests; a manual retry can create
a visible, manually deletable duplicate; and a failed batch leaves no partial
writes.

### 2. Finish the diary and fast food logging

- Add recent-item loading for the selected date and meal slot using
  `/logs/recent-items`; preserve server ranking rather than inventing local ranks.
- Expose All, History, Custom, and Barcode modes. Add category suggestions using
  `/foods/categories`; protect against stale search/scope responses.
- Prefill quantity/unit from `/logs/last-used`. A late default must not overwrite
  user edits; unavailable units fall back visibly to a valid choice.
- Add recent quantity chips and quick-add through the shared submission path.
- Add batch selection with a review step showing date, slot, items, and amounts.
- Add “Log latest” on eligible empty slots using `/logs/latest-slots`, matching
  the web's 30-day lookback and server-supported date semantics. Show the source
  date and copied items before submission; handle no-history and deleted items.
- Refresh totals and affected slot rows after confirmed success without changing
  the selected date. Show actionable errors and let the user retry explicitly;
  do not automatically replay an uncertain submission.
- Introduce Barcode mode here with its complete lookup behavior from milestone 6;
  do not ship a dead tab while that work is pending.

Exit: a historical-day quick-add/repeat journey retains its date and slot. A
manual retry may create a duplicate, which is acceptable and can be deleted
manually. Meal rows join this flow in milestone 5.

### 3. Add per-day nutrition details

- Add the native API/DTO/adapter for the existing daily nutrient-report surface;
  use `frontend-web/src/Data/NutritionDetails.elm` and backend contracts as the
  parity reference rather than deriving the report from current food data.
- Open the report from the diary for the selected day. Show nutrient totals,
  units, reference amounts, progress where meaningful, and coverage warnings.
- Distinguish unknown/missing values from zero and unavailable references from
  zero targets. Preserve the server's guidance and reference interpretation.
- Add expandable guidance, reference/source context, empty/error/retry states,
  and accessible presentations for narrow and wide layouts.

Exit: fixture comparisons match the web report, including partial coverage,
missing references, and historical snapshot nutrition.

### 4. Build Library and ad-hoc logging

- Add custom-food list/create/detail/edit/delete using existing catalog routes.
- Build a shared validated nutrient editor with decimal input, explicit units,
  per-100 g values, and optional-versus-zero handling. Match web create/edit
  distinctions: creation does not require a serving; editing supports servings.
- Enforce server ownership/validation results, confirm deletion, and explain
  that existing diary snapshots do not change when a food is edited or deleted.
- Add one-off ad-hoc logging without creating a catalog entry.
- Add “Save food and log”: confirm the food creation first, retain its returned
  ID, then submit the log with an ordinary POST. If logging fails, the user can
  retry logging that saved food; never silently recreate the food.
- Report an uncertain custom-food create outcome and refresh the list; do not
  add an operation journal, intent ledger, or server operation support. A
  deliberate retry may create a duplicate food, which the user can delete.

Exit: custom-food CRUD, ad-hoc logging, and save-then-log pass validation,
ownership, and deletion checks. A manually retried create may leave a duplicate
that is visible and deletable; no automatic duplicate protection is required.

### 5. Build Meals and integrate logging

- Add meal list/create/detail/edit/delete and portion nutrient preview using
  `/meals` and `/meals/{id}/nutrients`.
- Support product components, quantities/units, notes, and total recipe quantity
  according to backend rules. Do not introduce nested/recursive meals.
- Handle invalid or deleted components and discard confirmation for dirty forms.
- Extend selection, log-form models, request building, and session context from
  food-only IDs to typed product/meal references to avoid identifier collisions.
- Make meals selectable in the add flow and available in recent rows, last-used
  defaults, quick-add, and batch/repeat. Do not imply the food search API searches
  meals if it does not; compose supported sources with clear labels.

Exit: create a meal, preview a portion, log it on a historical date, retry
manually if needed, and verify later recipe edits do not rewrite logged nutrition
snapshots. A manual retry may create a duplicate log, which is acceptable.

### 6. Add barcode lookup and reviewed assistant drafting

Status: implemented for manual barcode lookup and text AI drafting. Camera
scanning and image-based drafting remain intentionally deferred and are not
exposed in the native UI.

- Ship manual barcode lookup first using `/foods/barcode/{barcode}`. Preserve
  leading zeros; match supported barcode validation and show local/import origin.
- Handle not-found after local/OFF lookup, upstream failure, and direct creation
  of a custom-food draft with the barcode retained where supported.
- Optional separate camera increment is **not implemented**: native scanning on
  supported devices, deliberate detection confirmation, denied-access fallback,
  and resource cleanup remain future work. Manual entry remains available on
  macOS and unsupported devices.
- Gate assistant entry on `/ai/food-assistant/status`. The native client decodes
  `supports_images` but exposes no image picker or image upload; drafting is
  text-only. Implement both custom-food and ad-hoc-log draft purposes through the
  existing server endpoint; handle conversation, warnings, cancellation, and
  rate limits.
- Treat all AI output as editable draft data. Explicit review must precede a
  separate save/log action; drafting never writes.
- Image drafting is deferred. If it is added later, use system photo selection
  and request camera access only when capture starts. Do not request broad photo
  access at launch or promise image support when the server reports it
  unavailable.

Exit: manual lookup and text drafting work without camera/photo permissions;
AI unavailable, invalid drafts, and cancelled requests are safe. Camera scanning
and image drafting remain explicit deferred product decisions, not shipped
features.

### 7. Finish account settings

- Add normal-user personal API-key list/create/revoke from Account Settings.
- Support names, supported scopes, optional expiry, limits, validation, and
  confirmed revocation, matching the existing web/API behavior.
- Reveal a newly created secret once with deliberate copy/dismiss controls.
  Never persist or log it, include it in diagnostics, or attempt to retrieve it
  again. Report an uncertain create outcome and refresh the list; do not add a
  durable intent ledger or retry automatically.
- Clear secret UI state on dismissal, sign-out, or account change; obscure it
  when the app becomes inactive. Test clipboard behavior without real secrets.
- Keep Apple-default appearance and English-only behavior unless a separate
  product decision changes those requirements.

Exit: a normal session can create and revoke a key; later list/detail responses
and native persistence contain no recoverable secret.

## No-replay policy boundary

This section replaces the former server-first idempotency rollout. CalCo
deliberately does not provide automatic replay or duplicate-submission
protection for food-log creation. If a create is retried or submitted twice, a
duplicate food log is acceptable: the user can see it and delete it manually.

- Do not require capability negotiation, durable operation journals, request
  fingerprints, tombstones, prepared-intent ledgers, or account-binding headers
  for new write paths.
- Do not apply or reconstruct the withdrawn operation migrations. They are
  removed, not pending rollout. Their source files
  `20261119000000_food_log_create_operations.sql` and
  `20261119000001_food_log_create_operations_log_count.sql` are deleted and were
  confirmed unapplied; old instructions to apply them are historical and must
  not be followed. No DB schema, drop, or migration-history change was made.
- The existing `20261115000001_food_log_idempotency.sql` baseline, the
  preexisting baseline legacy single-food FoodDetail journal, and the server's
  existing optional key behavior preexisted this rollback and remain outside it.
  The policy does not claim they were removed. They are historical baseline
  code, not a policy requirement for new flows, and they do not override the
  decision.
- There are no new request fingerprints outside that baseline legacy path, and
  no generic durable catalog, meal, or API-key intent ledgers.
- Historical API documentation for the abandoned idempotency-key or operation
  API is pre-decision documentation and does not override the accepted
  [no-replay decision](decisions/2026-11-20-no-replay-protection.md).
- Ordinary validation, authentication, ownership, and atomic batch behavior
  remain required.

## Cross-cutting completion gates

Every milestone includes its tests and documentation, not a deferred test phase:

- Pure validation/state tests and injected-service tests for loading, empty,
  cancellation, stale responses, authorization failures, and explicit error or
  retry states.
- API contract tests for decimals, nullable fields, units, and structured errors.
- Backend behavior changes follow `backend/AGENTS.md` and `docs/backend.md`. Any
  required existing baseline migrations are applied explicitly; PostgreSQL-backed
  tests remain for ordinary write guarantees.
- Stable accessibility identifiers, VoiceOver labels, Dynamic Type, keyboard
  navigation, native confirmation controls, and unsaved-change protection.
- iPhone narrow layout, iPad compact/expanded layouts, and native macOS builds
  and interaction checks. Test multiple windows against ordinary shared UI state.
- Isolated E2E journeys only; no mutation of the user's live diary. Do not make
  duplicate-safety claims for new flows: UI row counts are not a guarantee about
  server record counts, and duplicates are accepted by policy.
- Update `frontend-ios/README.md` with new destinations, privacy behavior, and
  supported workflows. Keep user secrets out of logs, screenshots, and fixtures.

Final status: the normal features are implemented and current rollback
validation passed for the available gates. Native unit is **601/601** (0
failures, 0 skips, 0 expected) on the exact iPhone 13 mini, native Mac arm64
(`My Mac`), and iPad Air 11-inch (M4). Mini UI is **24/24**, and iPad Air
portable UI is **7/7**; both have 0 failures, 0 skips, and 0 expected failures.
The ordinary 503 retry check produced one log from two explicit user attempts,
with no capability endpoint and no account-binding header; the mock rejected
`X-CalCo-Account-ID` with 400 and the runtime passed both checks. Python helper
suites passed 11/11 mock, 11/11 driver, and 29/29 dev helpers. The earlier
751/751 native unit and 26/26 mini UI results are historical pre-rollback
artifacts, not current verification. Mac UI executed 0 app tests and remains
blocked by the user's decision after the automation initialization timeout; no
runtime Mac permission work or retry is planned. The exact iPhone Duo device/type
is absent from Xcode 26.6 and was not substituted. The backend is at the exact
`0ad3` baseline including migrations: 330 unit tests green with 0 failures, 4
existing ignored baseline tests visible, and 62 integration tests green with 0
failures. The withdrawn operation migrations are removed, their source files are
deleted and confirmed unapplied, old apply instructions are historical, and no
DB schema, drop, or migration-history change was made. Camera/photo capture and
image AI drafting remain deferred product decisions with English-only,
Apple-default UI. No new analytics, export, admin, theme, or language scope is
implied.
