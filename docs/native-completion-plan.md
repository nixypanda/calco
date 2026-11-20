# Native client completion plan

Status: **implemented; mini + iPad verified; Mac unit verified / Mac UI blocked
by user decision; iPhone Duo unavailable** (updated 2026-11-20). The project is
not fully accepted across every device class. See
[Implementation status](#implementation-status),
`docs/native-completion-qa.md`, and `docs/native-device-acceptance.md`.

## Scope and baseline

Complete the normal-user workflows in `frontend-ios` for iOS 26, iPadOS 26,
and native macOS 26. Keep Apple-default appearance, English-only strings, and
Apple frameworks only. Do not add admin tools, browser theme controls, or Hindi
localization as incidental parity work.

Implemented and verified on mini and iPad normal-user scope:

- Diary navigation, log editing/deletion, goals, enabled slots, historical
  retention, and selected-date preservation across feature sheets.
- Durable account-scoped logging with session-generation-bound send context for
  single, batch, ad-hoc, and meal submissions, including quick-add, repeat
  latest, last-used prefill, and recovery.
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

| Milestone | Status |
| :--- | :--- |
| 0. Baseline and shared contracts | Implemented; 751 unit tests pass; mini UI 26/26 |
| 1. Retry-safe new logging paths | Implemented; server operation journal and capability v2 |
| 2. Diary and fast food logging | Implemented |
| 3. Nutrition details | Implemented |
| 4. Library and ad-hoc logging | Implemented, including uncertain-create reconciliation |
| 5. Meals and logging integration | Implemented, including degraded missing-component repair/delete |
| 6. Barcode and assistant drafting | Implemented for manual barcode and text AI; camera and image drafting deferred |
| 7. Account settings API keys | Implemented |
| Final interactive/device acceptance | Mini + iPad UI passed; Mac UI blocked by user decision; Duo unavailable |

Current native unit baseline: **751 test methods; 751 passed, 0 failures, 0
skipped** on the exact iPhone 13 mini and iPad Air 11-inch (M4) after the
iOS-only Library toolbar fix. Native Mac production also passed **751/751**
with the one-line pasteboard compile fix applied; that is an actual run, not a
diagnostic. The Mac branch was unchanged by the iOS-only Library fix. No new
unit tests were added for the toolbar fix. Independent runtime results and
artifacts/logs are retained.

The current mini UI gate is **26/26 passed, 0 failed, 0 skipped, 0 expected
failures** on the exact iPhone 13 mini (`90964888-D59F-41EC-8DA2-419C829F3A71`)
at 375 x 812 points. The iPad Air portable UI gate is **7/7 passed, 0 failed, 0
skipped, 0 expected failures** on `C9CE77F1-89E8-4DF5-B101-871105BCED9B`. These
cover enabled AI custom/ad-hoc draft review with no write until explicit save,
full Meals CRUD including degraded missing-component repair and delete, Library
full CRUD with save-and-log, the 44 x 44 Library Add/AX fix, and accessibility
XXXL.

Mac UI was not accepted: the runner executed **0 app tests** and failed
initialization with `Timed out while enabling automation mode`. The user chose
to leave Mac UI blocked; no permission change or retry is planned. This is a
runner/system initialization failure, not a product assertion failure. The
exact iPhone Duo device/type is absent from Xcode 26.6 and no substitute was
used.

Backend suites are independently reported green at **330 unit tests**, with **4
additional ignored existing baseline tests kept visible**, and **86 integration
tests green**. The operation migrations `20261119000000` and `20261119000001`
remain **unapplied in the app database**.

Latest acceptance result bundles and their approved temporary base paths are
listed in `docs/native-device-acceptance.md`; the mini QA bundle is listed in
`docs/native-completion-qa.md`.

The milestones below remain the acceptance and regression checklist. Implementation
is complete; mini and iPad verification passed, while Mac UI remains blocked by
the user decision and iPhone Duo is unavailable.

## Delivery order

The original delivery order is retained as the review and regression sequence.
Imperative bullets below describe the completed acceptance criteria, not
outstanding implementation tasks, unless the status table marks a deferred item.
Keep future fixes small and independently reviewable; do not combine unrelated
work into one change.

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

### 1. Make every new logging path retry-safe

This is a prerequisite for quick-add, repeat, batch, meal, and ad-hoc logging.

- Preserve the existing single-log key/fingerprint behavior. Replay returns the
  operation's current log rows in their original order; later edits are visible,
  and replay is not a stored response snapshot.
- Add backend idempotency support for batch and ad-hoc creation. Verify
  `GET /api/capabilities` reports `log_creation_idempotency.version >= 2` before
  sending those keys. If the route is absent or reports a lower version, gate
  ad-hoc/batch keyed retries off.
- Define an atomic batch contract: one durable operation key for the complete,
  ordered batch; replay returns the operation's current logs in original order,
  changed payload/order/route conflicts, and a failed batch leaves no partial
  writes. Finalize this contract before implementing the native batch adapter.
- Deploy the log-idempotency migrations and the backend before enabling gated
  native paths. Mark uncertain entries created before version 2 was verified as
  reconciliation-only; never replay them, because pre-migration deleted keys
  cannot be reconstructed.
- Generalize journal entries to typed product/meal/ad-hoc/batch submissions with
  schema migration for existing pending entries. Persist payload and key before
  sending; reuse them after timeout, navigation, relaunch, or double taps.
- New intentional submissions get new keys, even for identical food/quantity.
  Uncertain submissions cannot silently become new operations after an edit.
- Preserve account isolation, bounded storage, explicit recovery, shared-window
  coordination, and deletion barriers for every affected log in a batch.
- Treat server operation tombstones as permanent for the profile lifetime; there
  is no key-reuse window. Retrying must never recreate a deleted log. Fail closed
  if a pending journal cannot be read or written. If a malformed operation is
  reported, use reconciliation with a new key rather than replaying.

Exit: database-backed tests prove concurrent and lost-response retries persist
exactly one logical operation, conflicting payloads fail, and batch writes are
atomic. Native tests cover restart, account switching, and recovery.

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
  the selected date. Show actionable errors and pending-operation recovery.
- Introduce Barcode mode here with its complete lookup behavior from milestone 6;
  do not ship a dead tab while that work is pending.

Exit: a historical-day quick-add/repeat journey retains its date and slot, and
retry creates no duplicate records. Meal rows join this flow in milestone 5.

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
  ID, then submit the log through the journal. If logging fails, retry logging
  that saved food rather than creating it again.
- Define reconciliation for an uncertain custom-food create response; do not
  blindly retry a non-idempotent create. Add server operation support if needed.

Exit: custom-food CRUD, ad-hoc logging, and save-then-log pass validation,
ownership, deletion, and lost-response tests without unintended duplicate foods.

### 5. Build Meals and integrate logging

- Add meal list/create/detail/edit/delete and portion nutrient preview using
  `/meals` and `/meals/{id}/nutrients`.
- Support product components, quantities/units, notes, and total recipe quantity
  according to backend rules. Do not introduce nested/recursive meals.
- Handle invalid or deleted components and discard confirmation for dirty forms.
- Extend selection, log-form models, request building, and journal context from
  food-only IDs to typed product/meal references to avoid identifier collisions.
- Make meals selectable in the add flow and available in recent rows, last-used
  defaults, quick-add, and batch/repeat. Do not imply the food search API searches
  meals if it does not; compose supported sources with clear labels.

Exit: create a meal, preview a portion, log it on a historical date, retry safely,
and verify later recipe edits do not rewrite logged nutrition snapshots.

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
  separate save/log action through milestones 4 and 1; drafting never writes.
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
  again. Handle an uncertain create outcome by refreshing metadata, not blindly
  issuing another key creation request.
- Clear secret UI state on dismissal, sign-out, or account change; obscure it
  when the app becomes inactive. Test clipboard behavior without real secrets.
- Keep Apple-default appearance and English-only behavior unless a separate
  product decision changes those requirements.

Exit: a normal session can create and revoke a key; later list/detail responses
and native persistence contain no recoverable secret.

## Server-first rollout and retry retention

Deploy the backend and migrate PostgreSQL before enabling keyed ad-hoc/batch
native submission paths. Required order after the existing key/fingerprint
baseline:

1. `20261115000001_food_log_idempotency.sql` — existing single-log key and
   fingerprint columns.
2. `20261119000000_food_log_create_operations.sql` — baseline durable operation
   journal, ordered links, and backfill of existing keyed single logs.
3. `20261119000001_food_log_create_operations_log_count.sql` — additive upgrade
   that derives/validates `log_count` and installs the permanent-retention
   constraints without dropping or rewriting keys or tombstones.

As of 2026-11-20, `20261119000000_food_log_create_operations.sql` and
`20261119000001_food_log_create_operations_log_count.sql` remain **unapplied in
the app database**. This documentation update did not apply migrations.

Run migrations explicitly before the updated backend is exposed:
`just migrate-backend` for local development, or the deployment's migration step.
Never edit applied migration checksums, delete `_sqlx_migrations` history, or
drop/recreate the operation tables to force an upgrade.

After deployment, verify authenticated `GET /api/capabilities` reports
`log_creation_idempotency.version: 2` with the required route support and the
exact `request_account_binding: "x-calco-account-id"` value before clients resume
keyed batch/ad-hoc retries. A missing route, `version < 2`, a missing or unknown
binding flag, or an unready journal is fail-closed.

Protected native requests send `X-CalCo-Account-ID` with the authenticated
**user-profile UUID**, which is distinct from the identity ID used as the local
journal scope. The auth/root client remains unbound for login, restore, and
logout; each signed-in feature graph uses an immutable profile-bound client from
the shared session authority. A missing profile fails closed, and operations
whose legacy account binding cannot be verified remain reconciliation-only.

A capability `503`/transient 5xx or transport failure is not version 0. Keep the
pending operation's exact body and key, retry the probe later, and do not clear
or downgrade the entry. Only a verified version-2 journal may reserve or replay a
keyed non-single operation.

Operation rows, keys, and child links are permanent for the lifetime of the user
profile. Deleted-operation replay returns `409 conflict` and creates nothing;
there is no key-reuse window. Legacy entries created before version 2 was
verified, including migrated pre-v2 journal entries, are reconciliation-only and
must never be replayed. The server cannot reconstruct a key whose log was
deleted before the operation journal existed.

## Cross-cutting completion gates

Every milestone includes its tests and documentation, not a deferred test phase:

- Pure validation/state tests and injected-service tests for loading, empty,
  cancellation, stale responses, authorization failures, and uncertain writes.
- API contract tests for decimals, nullable fields, units, and structured errors.
- Backend behavior changes follow `backend/AGENTS.md` and `docs/backend.md`, with
  migrations applied explicitly and PostgreSQL-backed tests for write guarantees.
- Stable accessibility identifiers, VoiceOver labels, Dynamic Type, keyboard
  navigation, native confirmation controls, and unsaved-change protection.
- iPhone narrow layout, iPad compact/expanded layouts, and native macOS builds
  and interaction checks. Test multiple windows against shared submission state.
- Isolated E2E journeys only; no mutation of the user's live diary. Assert server
  record counts for duplicate-safety claims, not just the number of visible rows.
- Update `frontend-ios/README.md` with new destinations, privacy behavior, and
  supported workflows. Keep user secrets out of logs, screenshots, and fixtures.

Final status: implementation is complete; acceptance is limited to mini UI and
iPad UI passage plus Mac unit verification. Mac UI remains blocked by user
decision and is not accepted. The current native unit baseline
is 751/751 passed with 0 failures and 0 skipped on mini and iPad after the
iOS-only Library toolbar fix; Mac production unit was 751/751 with the one-line
pasteboard fix and an actual run, with the Mac branch unchanged by the iOS-only
fix. The mini UI gate is 26/26 passed with 0 failures,
0 skipped, and 0 expected failures. The iPad Air portable UI gate is 7/7 passed
with 0 failures and 0 skipped. Mac UI executed 0 app tests and remains blocked
by the user's decision after the automation initialization timeout; no permission
change or retry is planned. The exact iPhone Duo device/type is absent from Xcode
26.6 and was not substituted. Backend suites are independently reported at 330
unit tests green, with 4 additional ignored existing baseline tests kept visible,
plus 86 integration tests green. The operation migrations
`20261119000000` and `20261119000001` remain unapplied in the app database.
Camera/photo capture and image AI drafting remain deferred product decisions.
No new analytics, export, admin, theme, or language scope is implied.
