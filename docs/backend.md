# Backend

## Overview

The backend is a Rust service built with axum and sqlx. The code is organized
by bounded context first. `auth`, `import`, and `assistant` nest their layers
directly; `journal` is feature-first, with one folder per sub-context, each
nesting its own layers:

```text
backend/src/
  lib.rs                 # AppState, build_app_state, build_router
  auth/
    domain.rs
    app/
      api_key.rs
      ...
    infra/
      mod.rs
      argon2_credentials.rs
      pg/
        mod.rs
        api_key_repo.rs
        ...
    api/
      mod.rs
      http.rs
    module.rs
  import/
    domain.rs
    app.rs
    infra/
      mod.rs
      pg.rs
    api/
      mod.rs
      http.rs
    module.rs
  assistant/
    domain.rs
    app/
      mod.rs
      food_draft.rs
    infra/
      mod.rs
      admission.rs
      catalog.rs
      images.rs
      food_draft/
      llm/
    api/
      mod.rs
      http.rs
    composition.rs
  catalog/
    error.rs             # CatalogError
    api/
      mod.rs
      http.rs
      shared.rs           # shared HTTP helpers
    module.rs            # CatalogModule composition root
    domain/
      mod.rs
      calculation.rs     # Quantity, CalculatedNutrition, NutritionCalculator
      units.rs           # UnitConverter
      search_ranking.rs
    app.rs
    infra/
      mod.rs
      open_food_facts.rs
      pg/
        mod.rs
        iden.rs
        nutrient_repo.rs
        unit_repo.rs
        product/
          mod.rs         # PgProductRepo
          statements.rs
          rows.rs
          children.rs
          tests.rs
        shared.rs        # resolve_nutrient_ids, insert_chunked
  journal/
    error.rs             # JournalError
    api/
      mod.rs
      http.rs            # IntoResponse for JournalError
    module.rs            # JournalModule composition root
    meal/
      domain.rs
      app.rs
      infra/
        mod.rs
        pg.rs
      api/
        mod.rs
        http.rs
    food_log/
      domain.rs
      app/
        mod.rs
        history.rs
        services.rs
        test_support.rs
      infra/
        mod.rs
        pg.rs
      api/
        mod.rs
        dto.rs
        http.rs
    goals/
      domain.rs
      app.rs
      infra/
        mod.rs
        pg.rs
      api/
        mod.rs
        http.rs
    guidance/
      domain.rs
      app.rs
      infra/
        mod.rs
        static_guidance.rs
      api/
        mod.rs
        http.rs
    diary_prefs/
      domain.rs
      app.rs
      infra/
        mod.rs
        pg.rs
      api/
        mod.rs
        http.rs

All current contexts use the single-file shape. Catalog's shared HTTP glue
lives at `catalog/api/shared.rs`; journal's HTTP glue lives at `journal/api/http.rs`.

### Repository Ports

Repositories are persistence and query ports, not business-action services. Domain and application code own business decisions and state transitions, then hand already-decided state to the repository.

Single-entity write flow:

```rust
let updated = entity.operation(...)?;
repo.update(&updated).await?;
```

Multi-entity write flow:

```rust
let updated = entities
    .into_iter()
    .map(|entity| entity.operation(...))
    .collect::<Vec<_>>();

repo.update_many(&updated).await?;
```

Allowed repository method families:

- `create(&Entity)` and `create_many(&[Entity])`
- `find_by_<criteria>(...) -> Option<Entity>`
- `list_by_<criteria>(...) -> Vec<Entity>`
- `list_all(...) -> Vec<Entity>`
- `update(&Entity)` and `update_many(&[Entity])`
- `delete(id)` and `delete_many(&[Id])`
- Read-only aggregate queries such as `exists_by_<criteria>`, `count_by_<criteria>`, or `sum_by_<criteria>` when they are storage-shaped.

Naming rules:

- Use `create`, not `save`; `save` is ambiguous between create, update, and upsert.
- Use `find_by_*`, not `get_by_*`, for optional single-row lookups.
- Use `list_by_*` for multi-row lookups.
- Avoid `get_by_*` in repositories unless a future repository intentionally returns `T` and maps absence to an error.

Allowed examples:

```rust
find_by_id(id)
find_by_username(username)
list_by_user(user_id)
list_by_filter(user_id, filter)
update(&entity)
update_many(&entities)
delete(id)
delete_many(&ids)
```

Disallowed examples:

```rust
update_last_seen(session_id, now)
revoke_all_for_identity(identity_id)
disable_user(user_id)
mark_complete(id)
```

If the method name says what happened in the business, it belongs in domain or application code. If the method name says how to persist or query already-decided state, it can belong in the repository.

The import repository is an explicit exception for now because imports are primarily an infrastructure and data-ingestion workflow. Do not use import repository patterns as precedent for normal domain repositories.

## API Design Notes

These notes capture endpoint choices surfaced during feature mapping.

### Consolidated Endpoints

- Food detail uses `GET /foods/{id}` and includes product nutrients and
  servings. Do not add separate public `GET /foods/{id}/nutrients` or
  `GET /foods/{id}/servings` endpoints unless partial loading becomes necessary.
- Barcode lookup uses `GET /foods/barcode/{barcode}`. It checks the actor-visible
  local catalog first and calls Open Food Facts only on a miss. A usable OFF
  result is persisted before the response is returned.
- Log history uses `GET /logs?log_date=YYYY-MM-DD` for a single-day view. Do not
  add a separate `GET /logs/day/{date}` endpoint.
- Nutrition summaries use
  `GET /logs/summary?from_date=YYYY-MM-DD&to_date=YYYY-MM-DD`. Use the same date
  for both parameters for daily totals. The response includes energy and macro
  totals per day.
- Goal targets use `GET /goal?date=YYYY-MM-DD` to resolve the effective targets
  for a selected day and `PUT /goal` to create or overwrite the current day's
  saved targets.
- Diary preferences use `GET /diary-preferences` and
  `PUT /diary-preferences` to read or replace a user's enabled meal slots.
- Meals use aggregate-shaped endpoints: `POST /meals`, `GET /meals`,
  `GET /meals/{id}`, `PUT /meals/{id}`, `DELETE /meals/{id}`, and
  `GET /meals/{id}/nutrients?amount=&unit=`.
- Food logs accept `item.type` values of `product` and `meal`.
- Import APIs are admin-only and include staging endpoints for foods, nutrients,
  and servings.

### Repeat Logging

- Repeat logging uses a fetch plus batch-create flow:
  `GET /logs/latest-slots` finds, for every meal slot at once, the latest prior
  date with one or more logs for the requested user, and `POST /logs/batch`
  creates copied logs for the target date and same slot.
- `GET /logs/latest-slots` returns `{ "slots": [...] }`. Meal slots with no
  logs inside the lookback window are absent from the array rather than present
  with an empty item list. Each item uses the full `LogResponse` shape,
  including `notes`, device timezone, and snapshots.
- `GET /logs/latest-slots` should use a bounded lookback window. The frontend
  currently requests 30 days.
- `POST /logs/batch` should construct new logs through the same application
  service path as single log creation, so copied logs recalculate nutrient
  snapshots as new logs.
- Do not implement a separate repeat-last-single-item endpoint unless the
  product workflow changes. Current repeat behavior copies the whole latest
  non-empty slot.

### Identified API Gaps

- Add export job APIs when async exports are implemented: `POST /exports`,
  `GET /exports/{id}`, and `GET /exports/{id}/download`.
- Use the username/password auth flow from this document; OAuth/OIDC/Tailscale
  auth is out of scope.

### Custom-Food Create Reconciliation

`POST /foods/custom` is not idempotent. A client that loses the response cannot
tell whether the food was created, and retrying the same body can create a
duplicate custom food. No current catalog field is a safe natural idempotency
key: names are not unique, and barcode is optional and not accepted for every
custom food workflow.

The later "save food and log" workflow should not blindly retry an uncertain
create. If server support is added, follow the log-operation shape: a durable
operation key for custom-food creation, a normalized request fingerprint, a
replay response containing the same product ID, conflict on changed payload,
and a deletion/reconciliation policy that does not resurrect deleted food. That
requires a catalog-owned operation table and an atomic product-plus-children
write; the current food-log operation journal cannot safely represent catalog
creates. Until then, clients should recover by refreshing `GET /foods/custom`
and asking the user to reconcile rather than issuing another create.

### Aggregate Roots

Current aggregate roots:

- `Identity`, `UserProfile`, `Session`, and `ApiKey` for auth.
- `Product` for catalog foods.
- `FoodLog` for logged entries and nutrient snapshots.
- `Meal` for reusable user-defined meals.
- `GoalTarget` for user calorie and macro targets effective from a local date.
- `DiaryPrefs` for a user's enabled diary meal slots.
- `ImportJob` for staging and committing external catalog data.

Owned child values:

- `ProductNutrient` and `ProductServing` belong to `Product`.
- `FoodLogNutrientSnapshot` belongs to `FoodLog`.
- `MealComponent` belongs to `Meal`.
- `EnabledMealSlots` belongs to `DiaryPrefs`.
- Staged product/nutrient/serving rows and import errors belong to `ImportJob`.

Child values are not exposed as independently mutable resources. They are changed through their parent aggregate.

### Value Objects

The domain uses narrow value types for identifiers, codes, names, units, meal slots, quantities, nutrient amounts, and source values. This makes invariants explicit near the domain layer and limits raw string/UUID handling to boundaries.

### Historical Snapshots

Food logs snapshot nutrients at log time. This is the central data-integrity rule.

Consequences:

- Editing a custom food does not rewrite old logs.
- Importing updated catalog data does not rewrite old logs.
- Summaries read `food_log_nutrients`, not `product_nutrients`.
- Admin correction APIs are not needed for historical stability.

### Auth Separation

`Identity` is for authentication. `UserProfile` is for application data ownership.

Normal food-tracking data is keyed by `user_profiles.id`, not `identities.id`.
Admin identities exist for account recovery and import operations and do not
satisfy normal user extractors.

Personal API keys belong to a normal user identity, store a snapshot of its
security stamp, and resolve to the same `UserProfile` as a browser session.
Admin identities cannot create or use them. Key authentication is never an
alternative path to admin or import authorization.

Browser-session `last_seen_at` is refreshed best-effort at roughly 60-second
intervals. Update failures are ignored, and a stale heartbeat cannot clear a
concurrent logout's revocation.

### Imports As Anti-Corruption Layer

External datasets are converted into a normalized staging format before they reach the catalog. The import module validates rows, records row-level errors, and commits staged rows into catalog tables.

CLI scripts are the operational interface for imports. Browser import UI is intentionally out of scope.

## Personal API Keys

Personal API keys let a signed-in user call normal user-data routes with
`Authorization: Bearer` instead of a browser session cookie. Keys belong to an
`Identity`, authorize as a normal user, and resolve to that identity's
`UserProfile`. Existing authorization and ownership checks remain the source of
truth.

See [api-access.md](api-access.md) for the user-facing workflow and examples.

### Token Model

- Token format is `calco_pat_` followed by 32 random bytes encoded as
  base64url without padding.
- Only the SHA-256 hex hash is stored in `api_keys.token_hash`. The unique
  constraint provides the lookup index.
- `api_keys.token_hint` stores the first 18 characters for display.
- The raw token is returned only from the create endpoint with
  `Cache-Control: no-store`. It is never stored, logged, or accepted in a URL.
- SHA-256 is used instead of a password hash because the token is
  machine-generated with 256 bits of entropy and is not user-chosen.

### Scopes And Extractors

| Extractor | Authentication | Key scope | Use |
| --- | --- | --- | --- |
| `SessionUser` | Browser session cookie only | Not applicable | API-key management and assistant routes |
| `ReadUser` | Bearer key or browser session | `read` or `read_write` for keys | Read routes |
| `WriteUser` | Bearer key or browser session | `read_write` for keys | Mutating user-data routes |
| `AuthAdmin` | Admin session cookie only | Not applicable | Admin and import routes |
| `RawSessionToken` | Session cookie only | Not applicable | Session and logout routes |

`ReadUser` and `WriteUser` resolve authentication in this order:

1. If an `Authorization` header is present, require a valid `Bearer <token>`
   form. Authenticate through `ApiKeyService`, which returns `ApiKeyAuth` with
   the resolved identity, profile, and scope. Do not fall back to a cookie.
   Require a normal user role, an active identity, and a profile. Enforce the
   scope shown above.
2. Otherwise, use the existing browser session path.

An invalid bearer key returns `401 invalid_api_key`. A valid key with
insufficient scope returns `403 insufficient_scope`. `SessionUser` always uses
the browser session path and ignores `Authorization`; API keys cannot
authenticate key-management or assistant routes. `AuthAdmin` remains cookie-only
and likewise ignores `Authorization`.

### Expected Account Binding

Normal-user protected routes optionally accept:

```text
X-CalCo-Account-ID: <user_profiles.id UUID>
```

This is an assertion, never an authentication mechanism. The server resolves
the principal from the cookie or bearer key first, then compares the header to
that principal's `user_profiles.id`. It never uses the header to select or
impersonate a user.

- Header absent: allowed for backward compatibility.
- Header present and matching: request proceeds.
- Header present but not a single valid profile UUID: `400 invalid_account_header`.
- Header present, valid, but different from the authenticated profile:
  `401 session_account_changed`. The response does not include either profile ID.
- API-key scope and expiry are checked before account binding. A header cannot
  elevate a `read` key to a write route.

The guard is implemented with reusable account-bound extractors for
`ReadUser`, `WriteUser`, and `SessionUser`, so it runs before handler reads or
side effects. It applies to the normal-user routes in the scope mapping below,
including logs, catalog, meals, goals, diary preferences, nutrition details,
API-key create/list/revoke, assistant, and capabilities. `/auth/login`,
`/auth/session`, `/auth/logout`, admin routes, and import routes do not require
the header.

API keys are bound to the profile resolved from their claims, not to the
header. Assistant routes remain browser-session-only and use the same profile
comparison.

### Route Scope Mapping

Read routes use `ReadUser`:

- Catalog: `GET /foods/search`, `GET /foods/categories`,
  `GET /foods/barcode/{barcode}`, `GET /foods/{id}`, `GET /foods/custom`,
  `GET /nutrients`, `GET /nutrients/{code}`, `GET /units`.
- Logs: `POST /logs/last-used`; `GET /logs/recent-items`,
  `GET /logs/latest-slots`, `GET /logs/summary`, `GET /logs/{id}`,
  `GET /logs`.
- Nutrition details: `GET /nutrition/details`.
- Meals: `GET /meals`, `GET /meals/{id}`, `GET /meals/{id}/nutrients`.
- Goals: `GET /goal`.
- Diary preferences: `GET /diary-preferences`.

Write routes use `WriteUser`:

- Catalog: `POST /foods/custom`, `PUT /foods/custom/{id}`,
  `DELETE /foods/custom/{id}`.
- Logs: `POST /logs`, `POST /logs/ad-hoc`, `POST /logs/batch`,
  `PUT /logs/{id}`, `DELETE /logs/{id}`.
- Meals: `POST /meals`, `PUT /meals/{id}`, `DELETE /meals/{id}`.
- Goals: `PUT /goal`.
- Diary preferences: `PUT /diary-preferences`.

`POST /logs/last-used` is read-scoped even though it uses POST because it only
returns prefill data. Assistant routes remain `SessionUser` in v1. Admin and
import routes remain `AuthAdmin`, so no API key can use them.

`GET /foods/barcode/{barcode}` can persist an Open Food Facts product on a cache
miss. This existing read-path side effect is allowed for `read` keys.

### Management Routes

All three routes use `SessionUser`:

```text
GET    /auth/api-keys
POST   /auth/api-keys
DELETE /auth/api-keys/{id}
```

Create request fields:

- `name`: trimmed, 1 to 64 characters. Names must contain visible text and
  reject control and invisible formatting characters, including bidi controls,
  zero-width space, line/paragraph separators, BOM, and soft hyphen. ZWNJ and
  ZWJ are allowed inside normal text and emoji, but whitespace-only or
  invisible-only names are rejected.
- `scope`: optional `read` or `read_write`; defaults to `read`.
- `expires_in_days`: optional integer from 1 to 3650. Omission means the key
  never expires; the API does not apply the web UI's 90-day default.

Responses:

- Create returns `201` with the created key metadata and the raw `token`, plus
  `Cache-Control: no-store`.
- List returns metadata only: id, name, token hint, scope, created time, last
  used time, and expiry time.
- Delete returns `204`. Revocation is idempotent.
- Token hashes are never exposed.

`ApiKeyService::list` returns non-revoked keys that match the identity's current
security stamp, newest first. Expired keys are still returned; the web UI
displays their `expires_at` date but does not currently show a separate expired
badge.

### Limits And Lifecycle

- A user's 10-active-key cap is a best-effort application-level limit, not a
  database-enforced invariant. Concurrent creates can leave the account with
  more than 10 active keys, and the overage persists until a key is revoked or
  expires. Active means not revoked, not expired, and matching the current
  security stamp.
- Optional expiry is stored as `expires_at`. An expired key fails
  authentication.
- Revocation marks `revoked_at` immediately; there is no rotation endpoint.
  Create a replacement and revoke the old key.
- Admin password resets rotate the identity security stamp, invalidating all
  existing keys. Self-service password change is planned, not implemented.
- Disabling an identity rotates the security stamp and invalidates keys.
  Re-enabling does not restore old keys because the stamp is not reset back.
- `last_used_at` is refreshed best-effort and application-throttled to roughly
  once per 60 seconds. A failed metadata write is ignored and does not fail
  authentication, so the timestamp can remain stale. Concurrent requests may
  both refresh the timestamp. A heartbeat update does not clear a revocation.

### Persistence

The `api_keys` table stores:

- `id`, `identity_id` (referencing `identities`), and a snapshot of
  `identity_security_stamp`.
- `name`, `token_hash`, `token_hint`, and `scope`.
- `created_at`, `last_used_at`, `expires_at`, and `revoked_at`.

Constraints enforce a unique token hash, `scope IN ('read', 'read_write')`, a
name length from 1 to 64 characters, and `expires_at > created_at` when an expiry
is present. `identity_id` is indexed; `token_hash` relies on its unique
constraint. Raw tokens are never stored.

### Error Codes

| Status | Code | When |
| --- | --- | --- |
| `401` | `invalid_api_key` | Bearer token is malformed, missing a matching key, expired, revoked, or invalidated by a security-stamp change. |
| `403` | `insufficient_scope` | Valid key scope does not permit the route. |
| `404` | `api_key_not_found` | Key-management route referenced a key that is absent or owned by another identity. |
| `409` | `api_key_limit_reached` | The identity has at least 10 active keys according to the best-effort application check. |
| `400` | `invalid_api_key_name` | Name is empty, whitespace-only/invisible-only, longer than 64 characters, or contains a forbidden control/invisible formatting character. |
| `400` | `invalid_api_key_scope` | Scope is not `read` or `read_write`. |
| `400` | `invalid_api_key_expiry` | `expires_in_days` is outside 1 to 3650. |

Expired, revoked, and security-stamp-invalidated keys intentionally collapse to
the generic `401 invalid_api_key` response at the HTTP boundary. On
browser-session-only routes (key management, assistant, admin, and import), an
`Authorization` header is ignored; a bearer-only request fails with the session
rejection, normally `401 unauthorized`, not `invalid_api_key`.

### Security Behavior

- Key authentication requires a normal, active user identity and an existing
  profile. Admin identities and missing profiles fail closed.
- On `ReadUser`/`WriteUser` user-data routes, a malformed `Authorization` header
  is rejected and CalCo does not fall back to a cookie. Key-management,
  assistant, admin, and import routes ignore `Authorization` and use their
  session/cookie authentication.
- Keys remain subject to normal ownership checks, so cross-user access fails.
- API keys cannot manage keys, use admin or import routes, or use assistant
  routes.
- `AUTHORIZATION` and `X-CalCo-Account-ID` are included in the allowed CORS
  headers. This permits trusted tools to send bearer tokens and account
  bindings; it does not make embedded browser secrets safe.
- Raw tokens are never logged or returned outside the create response.

> **Warning:** `CORS_ALLOWED_ORIGINS` is a credential-minting trust boundary.
> When it is non-empty, the backend enables credentialed CORS for exactly those
> origins. Any listed origin can use a signed-in user's session cookie to call
> the cookie-authenticated key-management route and read the raw token from the
> create response. List only first-party origins you control; never add
> third-party or untrusted origins.

## HTTP Routes

All routes are mounted under `/api`.

### Health And Capabilities

```text
GET /health
GET /version
GET /capabilities
```

`GET /health` and `GET /version` are unauthenticated. `GET /capabilities` uses
`ReadUser` and is the authoritative feature/migration gate described under
Idempotent Log Creation; do not infer keyed-log readiness from `/health` or
`/version`.

### Auth

```text
GET  /auth/bootstrap/status
POST /auth/bootstrap/admin
POST /auth/login
GET  /auth/session
POST /auth/logout
```

Personal API key management (browser session only):

```text
GET    /auth/api-keys
POST   /auth/api-keys
DELETE /auth/api-keys/{id}
```

Admin user management:

```text
GET  /admin/users
POST /admin/users
GET  /admin/users/{id}
POST /admin/users/{id}/reset-password
POST /admin/users/{id}/disable
POST /admin/users/{id}/enable
```

Planned:

```text
POST /me/change-password
```

Profile read/update endpoints are intentionally out of scope.

### Catalog

```text
GET    /foods/search?q=
GET    /foods/categories
GET    /foods/barcode/{barcode}
GET    /foods/{id}
GET    /foods/custom
POST   /foods/custom
PUT    /foods/custom/{id}
DELETE /foods/custom/{id}
GET    /nutrients
GET    /nutrients/{code}
GET    /units
```

Food detail includes product nutrients and servings. There are no separate public nutrient/serving detail endpoints. Catalog reads use `ReadUser`; custom-food writes use `WriteUser`.

`GET /foods/barcode/{barcode}` trims the path value and uses local-first lookup.
Locally cached values are returned without an external request. Only an
uncached barcode is validated as 4 to 24 ASCII digits and sent to the Open Food
Facts v3 product API. The response has the same top-level food-detail fields as
`GET /foods/{id}`, plus lookup metadata. Abbreviated example:

```json
{
  "id": "product-uuid",
  "source": "OFF",
  "name": "Example food",
  "nutrients": [],
  "servings": [],
  "allowed_units": [],
  "lookup": {
    "origin": "open_food_facts",
    "note": "Food was not found locally and was imported from Open Food Facts."
  }
}
```

`lookup.origin` is `local` or `open_food_facts`; `lookup.note` is `null` for a
local match. An OFF match is stored as a globally visible `OFF` product using
the returned code as source ID and barcode. The adapter imports the name,
optional brand, up to 30 normalized categories, supported per-100 g nutrients,
and a gram-based `serving` conversion when one can be parsed. Nutrient amounts
are converted into the units of CalCo's nutrient catalog; unsupported units and
invalid or negative values are skipped.

Barcode-specific failures use the normal error envelope:

- `400 validation`: an uncached barcode is not 4 to 24 digits.
- `404 not_found`: neither the local catalog nor OFF contains the barcode.
- `502 external_invalid_response`: OFF returned malformed or unusable data.
- `503 external_unavailable`: the OFF request timed out or returned another
  unsuccessful status.

### Logs And Summaries

```text
POST   /logs
POST   /logs/ad-hoc
POST   /logs/batch
POST   /logs/last-used
GET    /logs/recent-items?from_date=&to_date=&meal_slot=
GET    /logs/latest-slots?before=&lookback_days=
GET    /logs/{id}
GET    /logs?log_date=YYYY-MM-DD
PUT    /logs/{id}
DELETE /logs/{id}
GET    /logs/summary?from_date=YYYY-MM-DD&to_date=YYYY-MM-DD
```

Use the same date for `from_date` and `to_date` for a single-day view. Log reads and
`POST /logs/last-used` use `ReadUser`; log mutations use `WriteUser`.

`GET /logs/recent-items` dedups logs to one entry per item and orders both the
items and each item's `top_quantities` by time-decayed usage frequency. Log age
is measured against the requested `to_date`, not today, so browsing a past day
returns the ordering that applied then. `quantity` stays the item's most
recently logged quantity, which `POST /logs/last-used` relies on for prefill.

`POST /logs` accepts:

```text
item.type = product
item.type = meal
```

#### Capabilities Discovery

`GET /capabilities` is authenticated and accepts the same `ReadUser` credentials
as log reads: a browser session or a `read`/`read_write` API key. It is the
rollout gate for keyed batch and ad-hoc retries. The `single`, `ad_hoc`, and
`batch` booleans mean keyed create support on those routes; unkeyed creates are
unaffected. `request_account_binding` is `"x-calco-account-id"` only on a
ready v2 server. Native logging must require that exact value before sending
requests; a missing field or an older server must be treated as unable to
enforce expected-account binding.

When the operation journal migration is present and complete:

```json
{
  "log_creation_idempotency": {
    "version": 2,
    "single": true,
    "ad_hoc": true,
    "batch": true,
    "batch_key_location": "top_level",
    "deleted_operation_replay": "conflict",
    "pre_migration_deleted_keys": "reconciliation_only",
    "request_account_binding": "x-calco-account-id"
  }
}
```

If the new binary starts before the journal migration, the route still responds
`200` but reports:

```json
{
  "log_creation_idempotency": {
    "version": 0,
    "single": false,
    "ad_hoc": false,
    "batch": false,
    "batch_key_location": null,
    "deleted_operation_replay": "unavailable",
    "pre_migration_deleted_keys": "reconciliation_only",
    "request_account_binding": null
  }
}
```

An older backend has no `/capabilities` route and returns `404` (or a non-JSON
not-found response). Clients must treat `404`, a missing field, a non-`200`
response, or `version < 2` as "do not send ad-hoc or batch idempotency keys".
Do not infer capability from `/health` or `/version`; those routes do not prove
the database migration exists.

If the readiness query itself fails, the route returns `503` with
`error.code = "capability_unavailable"`. A `503` is transient: retry and keep
the pending operation body. It does not mean version `0`, does not prove the
migration is missing, and must not trigger reconciliation-only cleanup.

Version 2 readiness is authoritative and checks the expected operation and
child columns, the unique `(user_id, idempotency_key)` index by its columns and
uniqueness (not by index name), the child primary key and `(operation_id,
food_log_id)` uniqueness, the prerequisite `food_logs` key columns/index,
`log_count` non-null, the `1..50` check, and the user/child foreign keys.

Rollout order is mandatory: apply all log-idempotency migrations, deploy the
backend, verify `GET /capabilities` reports version 2, then enable native
batch/ad-hoc keyed submissions. A client holding an uncertain entry created
before version 2 was verified must mark it reconciliation-only and must not
replay it. The server cannot reconstruct a key whose log was deleted before the
operation journal existed.

#### Idempotent Log Creation

Apply `20261115000001_food_log_idempotency.sql`,
`20261119000000_food_log_create_operations.sql`, and
`20261119000001_food_log_create_operations_log_count.sql` before starting the
updated backend. The NixOS deployment runs migrations before the backend, while
local development uses `just migrate-backend`. The first migration adds the
nullable key columns on `food_logs`; the second adds the durable operation
journal and backfills existing keyed logs; the third additively upgrades a
pre-`log_count` journal by deriving the expected child count from existing
links. Do not infer an original fingerprint from an edited log.

Never drop or rewrite `_sqlx_migrations` history, and never delete/recreate the
operation tables to force an upgrade. The additive migration preserves keys and
tombstones.

Supported upgrade paths:

- Fresh install: run `20261115000001`, `20261119000000`, then the additive
  `20261119000001`.
- Existing install that recorded the original `20261119000000` operation
  journal without `log_count`: run the additive `20261119000001`; it derives
  `log_count` from each operation's existing child links.
- Existing install with the original journal and legacy keyed logs: the initial
  migration's backfill and the additive migration are safe in that order.

Unsupported without explicit reconciliation:

- An install that recorded a different modified checksum for
  `20261119000000`: do not edit applied migration files or reset SQLx history;
  SQLx checksum validation will reject the changed baseline. Reconcile that
  environment explicitly.
- An operation with zero or more than 50 child links when the additive
  migration runs: the migration intentionally aborts rather than guessing a
  count. Repair the corrupt operation before retrying.

`POST /logs`, `POST /logs/ad-hoc`, and `POST /logs/batch` accept an optional
top-level `idempotency_key`. Omitting it, or sending `null`, preserves the
existing non-idempotent behavior. A supplied key must be 1 to 128 characters,
must not be blank, and must not contain control characters. Keys are scoped to
the authenticated user profile across all three logging routes and are never
returned in log responses.

`POST /logs/batch` accepts the key beside `items`, not inside an item. An item
level `idempotency_key`, including an explicit `null`, remains a validation
error rather than a silently ignored field. The batch key identifies the
complete ordered batch.

Request shapes:

```json
POST /api/logs
{
  "log_date": "2026-11-19",
  "meal_slot": "breakfast",
  "device_timezone": "Asia/Kolkata",
  "item": { "type": "product", "id": "..." },
  "quantity": { "amount": 150, "unit": "g" },
  "notes": "optional",
  "idempotency_key": "client-generated-key"
}
```

```json
POST /api/logs/ad-hoc
{
  "log_date": "2026-11-19",
  "meal_slot": "lunch",
  "device_timezone": "Asia/Kolkata",
  "name": "Ad-hoc food",
  "brand": null,
  "quantity": { "amount": 1, "unit": "serving" },
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount": 520, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount": 24, "unit": "g" },
    { "code": "CARBS_G", "amount": 48, "unit": "g" },
    { "code": "FAT_G", "amount": 25, "unit": "g" }
  ],
  "notes": null,
  "idempotency_key": "client-generated-key"
}
```

```json
POST /api/logs/batch
{
  "idempotency_key": "client-generated-key",
  "items": [
    {
      "log_date": "2026-11-19",
      "meal_slot": "breakfast",
      "device_timezone": "Asia/Kolkata",
      "item": { "type": "product", "id": "..." },
      "quantity": { "amount": 70, "unit": "g" },
      "notes": null
    }
  ]
}
```

Keyed creation contract:

- The first successful create returns `201 Created` with the normal response
  shape: one log for `POST /logs` and `POST /logs/ad-hoc`, or
  `{ "items": [...] }` for `POST /logs/batch`.
- A retry with the same key and the same normalized create input returns
  `200 OK` with the operation's logs in their original order. This is the
  original **operation identity and order**, not a stored response snapshot:
  logs are read from current rows, so later edits are visible. Nutrient
  snapshots remain the snapshots stored on those rows; replay does not
  recalculate nutrition or restore edited fields.
- Reusing the key with a different normalized payload, a different batch order,
  or a different logging route returns `409 conflict`.
- If any log created by the operation has since been deleted, replay returns
  `409 conflict` and creates nothing. A new intentional submission must use a
  new key.
- A malformed or incomplete operation also returns `409 conflict` and creates
  nothing. This includes zero child links, duplicate links, a child count that
  differs from the operation's stored `log_count`, a linked log owned by another
  user, or a linked log that can no longer be loaded. Replay never returns a
  partial list or an empty success.
- Validation, ownership, catalog, and persistence failures do not reserve the
  key unless the whole operation committed. The operation row, ordered child
  links, every food log, and every nutrient snapshot share one transaction. A
  database failure after an earlier log or nutrient insert rolls all of them
  back, so a failed batch leaves no partial rows and the key remains usable for
  a corrected retry.

The durable `food_log_create_operations` and
`food_log_create_operation_logs` tables store the key, a SHA-256 request
fingerprint, the operation kind, the expected log count, and the ordered log
IDs. Replay requires the child-link count to equal `log_count`, so independently
removing one link cannot turn a two-item batch into a valid-looking one-item
replay. Log lookups are scoped by the authenticated user in PostgreSQL as
defense in depth, and replay rechecks each returned log's owner and identity.
Operation child rows deliberately have no foreign key to `food_logs`, so
deleting a log leaves a tombstone instead of silently shrinking the operation.
The unique index on `(user_id, idempotency_key)` serializes concurrent retries;
the losing request reads the winning operation and replays it or returns a
conflict. The operation, every food log, and every nutrient snapshot are written
in one database transaction by `FoodLogRepo::create_operation`.

Retention is explicit and indefinite. Operation rows, keys, and their child
links are permanent for the lifetime of the user profile. There is no TTL,
pruning job, admin cleanup, or log-deletion path that removes a key or an
individual child link. Deleting a user profile cascades the operation and all
of its child links together; no other supported path deletes them. A future
retention protocol must replace the tombstone mechanism before any cleanup is
allowed to delete these rows. Adding a naive cleanup that frees keys would make
late client retries unsafe.

Single-create fingerprints are unchanged from the first migration: log date,
meal slot, normalized device timezone, item type and ID, normalized quantity
amount, exact quantity unit code, and notes. Ad-hoc fingerprints add the
trimmed name and brand, normalized quantity, and nutrients sorted by nutrient
code with normalized amounts and exact units. Batch fingerprints hash the
ordered list of single-item create inputs. Notes and keys are compared
byte-for-byte rather than Unicode-normalized. The fingerprint deliberately does
not store resolved catalog names or nutrient snapshots, so log edits and catalog
changes do not change it. Updates preserve the stored key and fingerprint.

`food_logs.idempotency_key` and `food_logs.request_fingerprint` remain populated
for keyed single and ad-hoc rows for backward compatibility, but the operation
journal is the replay source of truth. Migration backfill gives a legacy keyed
row with no fingerprint an impossible fingerprint so retrying it still returns
`409 conflict`. The backfill can only preserve keys whose logs still exist when
the migration runs; a key whose log was already deleted before the migration
cannot be reconstructed. Such a key can otherwise look unused and create a new
log, so a client must never replay an uncertain entry that was created before
version-2 capability was verified. Mark those entries reconciliation-only.

The migration must run before the backend binary is exposed to clients. After
deployment, verify `GET /capabilities` reports `version: 2`; only then enable
keyed ad-hoc and batch submissions in the native client. Applying the migration
after clients resume replays reopens the deleted-key window.

Reads of a food log and its nutrient snapshots use one repeatable-read
transaction, so a replay cannot combine a row from before an update or delete
with snapshots from after it.

### Nutrition Details

```text
GET /nutrition/details?date=YYYY-MM-DD
```

Returns per-nutrient known amounts, reference guidance, item counts, coverage,
and status for the requested day. It uses `ReadUser`.

### Meals

```text
POST   /meals
GET    /meals
GET    /meals/{id}
PUT    /meals/{id}
DELETE /meals/{id}
GET    /meals/{id}/nutrients?amount=&unit=
```

Meal requests are aggregate-shaped. There are no standalone meal-component
mutation routes. Meal reads use `ReadUser`; meal mutations use `WriteUser`.

#### Meals With Missing Ingredients

Catalog products are soft-deleted, but a meal keeps its typed component
references and quantities. `GET /meals` and `GET /meals/{id}` do not fail the
whole request when one component cannot be resolved. Each meal is returned in a
degraded but complete shape:

```json
{
  "id": "meal-id",
  "name": "Broken Porridge",
  "nutrition_summary": null,
  "has_missing_components": true,
  "components": [
    {
      "id": "component-id",
      "item": { "type": "product", "id": "deleted-product-id" },
      "quantity": { "amount": "200", "unit": "g" },
      "nutrition_summary": null,
      "missing": true,
      "missing_reason": "product_unavailable",
      "name": "Unavailable food"
    }
  ]
}
```

- Healthy components keep their normal `item`, `quantity`, and
  `nutrition_summary`; `missing`, `missing_reason`, and `name` are omitted.
- Healthy meals omit `has_missing_components`; clients must default it to
  `false`.
- A meal with any missing component has `nutrition_summary: null`; a component
  with a missing product has `nutrition_summary: null`. No partial nutrition is
  reported as complete.
- The component ID, typed product ID, and quantity are preserved. Do not drop
  the component or send it to update without an explicit replacement.
- The meal remains editable and deleteable. Repair by `PUT /meals/{id}` with a
  full `components` array containing only available products; a successful
  repair removes the missing markers and restores nutrition.
- `GET /meals/{id}/nutrients` and meal-based `POST /logs` / `PUT /logs/{id}`
  return `409` with `error.code = "missing_components"` instead of calculating
  false nutrition:

```json
{
  "error": {
    "code": "missing_components",
    "message": "meal has components that are no longer available; replace them before previewing or logging",
    "meal_id": "meal-id",
    "missing_components": [
      {
        "component_id": "component-id",
        "item": { "type": "product", "id": "deleted-product-id" },
        "quantity": { "amount": "200", "unit": "g" },
        "name": "Unavailable food",
        "missing_reason": "product_unavailable"
      }
    ]
  }
}
```

Existing meal-based food logs remain immutable snapshots. Deleting or repairing
a catalog product or meal does not rewrite stored log names, quantities, or
nutrient snapshots.

### Goals

```text
GET /goal?date=YYYY-MM-DD
PUT /goal
```

`GET /goal` resolves the target snapshot effective for the requested local date
and uses `ReadUser`. `PUT /goal` uses `WriteUser`.

`PUT /goal` saves the current day's target values using:

```text
local_date
device_timezone
calorie_target
protein_target_g
carbs_target_g
fat_target_g
```

The backend validates that `local_date` matches today's date in `device_timezone` and that calories equal `protein*4 + carbs*4 + fat*9`.

### Diary Preferences

```text
GET /diary-preferences
PUT /diary-preferences
```

The update replaces the authenticated user's enabled meal slots. At least one
known slot must remain enabled. `GET` uses `ReadUser`; `PUT` uses `WriteUser`.

### Imports

Admin-only and cookie-only through `AuthAdmin`; API keys cannot use these
routes:

```text
POST /imports
POST /imports/{id}/foods
POST /imports/{id}/nutrients
POST /imports/{id}/servings
POST /imports/{id}/commit
GET  /imports/{id}
GET  /imports/{id}/errors
```

### Assistant

Authenticated user routes (browser session only through `SessionUser`; API keys
cannot use these routes in v1):

```text
GET  /ai/food-assistant/status
POST /ai/custom-food/draft
```

`GET /ai/food-assistant/status` returns whether drafting is enabled and reports
`supports_images` from the configured provider capability.

`POST /ai/custom-food/draft` accepts `multipart/form-data` with exactly one
non-file `conversation` field and, when `supports_images` is true, up to four
`photos` file fields. Its JSON value is `{ "turns": [...] }`, with a non-empty
array of at most 20 `{ role, text }` turns. Roles are `user` or `assistant`, and
each trimmed text value is limited to 4,000 characters. Photos may be JPEG, PNG,
or WebP; each is limited to 5 MiB, their combined raw and normalized size to
12 MiB, and decoded input to 12 megapixels. Accepted photos are downscaled to a
maximum 2,048-pixel edge, re-encoded to remove metadata, and attached to the
latest user turn. The aggregate multipart body is limited to 13 MiB. Unknown
or duplicate conversation fields and photos for a text-only provider are
rejected. The response is either
`needs_clarification` with an assistant message or `draft_ready` with a complete
reviewable custom-food draft and warnings.

The route does not create or update catalog data. Clients explicitly submit an
accepted draft through `POST /api/foods/custom`. Per-user throttling and the
global in-flight limit return `429` with `Retry-After`; disabled AI returns
`503`, and provider failures are mapped to opaque `502` responses.

## Database

Migrations live in:

```text
backend/migrations
```

Run migrations explicitly with:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just migrate-backend
```

Important tables:

- Auth: `identities`, `user_profiles`, `sessions`, `api_keys`,
  `auth_audit_events`
- Catalog: `products`, `product_nutrients`, `product_servings`, `nutrients`, `units`
- Logs: `food_logs`, `food_log_nutrients`, `food_log_create_operations`,
  `food_log_create_operation_logs`
- Meals: `meals`, `meal_components`
- Goals: `goal_target_versions`
- Diary preferences: `diary_preferences`
- Imports: `imports`, `staging_products`, `staging_product_nutrients`, `staging_product_servings`, `import_errors`

`food_logs` stores an optional idempotency key and request fingerprint directly
on keyed single and ad-hoc logs. A partial unique index on
`(user_id, idempotency_key)` enforces per-profile uniqueness for those rows.
`food_log_create_operations` is the durable replay record for every keyed create
route. Its unique index on `(user_id, idempotency_key)` spans single, ad-hoc,
and batch operations. `log_count` records the expected number of child links so
partial link deletion is detectable, and child rows retain ordered log IDs after
log deletion so a late retry cannot recreate a removed log. Operation and child
rows are retained indefinitely; only deleting the owning profile cascades the
whole journal. Do not add TTL or cleanup code that deletes keys or individual
links.

Catalog search fetches storage-filtered candidate rows (scope and category
filters) from the repository. Matching and ranking are pure Rust in
`nutrition/catalog/domain/search_ranking.rs`.

Product search orders by tier: barcode exact → barcode prefix → name prefix →
name substring → brand prefix → brand substring → fuzzy, then similarity, then
normalized name, then product ID. `History` orders by recency first. Category
suggestions fetch counts and rank prefix → substring → fuzzy → count →
similarity → name.

Fuzzy matching uses trigram-containment similarity from `rust-fuzzy-search`
(`rust_fuzzy_search::fuzzy_compare`) with `DEFAULT_FUZZY_THRESHOLD = 0.50`.
Text is trimmed, whitespace-collapsed, and lowercased before comparison; the
crate returns `f32` scores, bounded in `0.0..=1.0` by `Similarity`. The score is
asymmetric: `fuzzy_compare(query, candidate)` measures how many of the query's
trigram occurrences appear in the candidate, so query stays the first argument.
Product name/brand/term fuzzy gates are inclusive (`>=`); category suggestion
fuzzy gates are exclusive (`>`), so exactly 0.5 passes the product gate
(`chese` vs `Chase`) but not the category gate.

The threshold was calibrated against a 30-case comparison, not the full
production catalog. The crate is pinned to `=0.1.1`; upgrades change the scores
and require recalibration. At 0.50:

- Word-order matches work: `milk almond` vs `Almond Milk` scores about 0.8333,
  and `yoghurt` vs `Greek Yogurt` scores 0.5 (accepted by the inclusive product
  gate, rejected by the exclusive category gate).
- Short near-misses mostly reject: `coke` vs `Cookies` and `rice` vs `rce` score
  0.4, `granila` vs `Rani` 0.25, and `almnd` vs `Salmon` about 0.1667.
- Some old matches are lost: `vegtable` vs `other-vegetables` scores about
  0.4444 and `cheese` vs `chess` about 0.4286.
- Some new fuzzy matches appear: `chiken` vs `Chicken Breast` scores about
  0.7143 and `chiken` vs `Grilled Chicken Breast` about 0.5714.
- Category suggestions inherit the raw metric: `vegtable` vs `vegetables`
  scores about 0.6667 and matches, while `vegtable` vs `feta` scores 0.0.

Search text is literal: `%` and `_` have no wildcard meaning, and `%` in
`100% Juice` is classified as substring and bypasses the fuzzy gate (its
similarity is still computed for tie-breaking). Text and barcodes are trimmed
and case-folded before matching. An empty query returns catalog results with
barcode-prefix matches first, while `History` keeps recency ordering.
Tie-breaking uses Rust string ordering rather than the PostgreSQL database
collation.

## Database Naming Conventions

PostgreSQL adapter names should keep persistence-specific concepts visible without leaking them into app or domain layers.

Type suffixes:

- `*Repo`: domain repository port trait.
- `Pg*Repo`: public PostgreSQL repository adapter implementing a `*Repo` port.
- `*Row`: private `sqlx::FromRow` query result type.

Function naming rules:

- Keep pure row-to-domain conversions as free functions, not repository methods.
- Use `{row_type}_row_to_{domain_type}` for row-to-domain conversion helpers, for example `product_row_to_product`.
- Use context-owned names when the row type is context-specific, for example `import_error_row_to_record`.
- Keep repository `impl` blocks focused on repository behavior, SQL execution, transactions, and data-loading helpers.
- Keep insert/update helpers outside repository `impl` blocks when they are shared by multiple repository methods or only need a transaction.

Statement constructors:
- Every private SQL builder that returns a sea-query `*Statement` must end in `_statement`. Do not use `_query`, `_sql`, or an unsuffixed name.
- Use entity-first naming: `{entity}_{operation}[_{qualifier}...]_statement`. The entity is the primary row/domain concept, including child tables such as `product_nutrient` or `meal_component`.
- Mirror repository port vocabulary for port-shaped operations: `create`, `find_by_{criteria}`, `list_all`, `list_by_{criteria}`, `update`, `delete`, `delete_by_{criteria}`, `upsert`, `exists_by_{criteria}`, `count_by_{criteria}`, and `sum_by_{criteria}`.
- For builders that are not direct port operations, use only `load`, `join`, `search`, `soft_delete`, `resolve`, or `insert_{variant}` / `delete_{child}`.
- Use `by_{criteria}` for predicates, `_and_` to join predicates, and `by_{target}_ids` or `for_{target}` for collection inputs.
- Child-table builders name the child entity, not the parent.

## Error Shape

HTTP errors use:

```json
{
  "error": {
    "code": "string",
    "message": "string"
  }
}
```

Some older docs mention `details`; the current handlers generally return `code` and `message`.

## HTTP Naming Conventions

HTTP boundary names should keep application and domain concepts first, with the HTTP-layer role expressed by the suffix.

Type suffixes:

- `*Request`: top-level JSON request body.
- `*Query`: URL query extractor.
- `*Response`: top-level JSON response body.
- `*Dto`: nested or reusable transport object.
- `*MetaDto`: nested transport metadata object, such as `BarcodeLookupMetaDto`.
- `*ItemDto`: element inside a list response.
- `*RowDto`: import staging row payload.
- `*Params` / `*RangeParams`: internal parsed handler data, not public API DTOs.

Function naming rules:

- Put the source domain/application concept first.
- Put the HTTP artifact or mapping target last.
- Use `*_request_to_input` for request-body to application-input conversion.
- Use `*_query_to_criteria` or `*_query_to_params` for query conversion.
- Use `*_to_response` for top-level response conversion.
- Use `*_to_list_response` for list response conversion.
- Use `*_to_dto` for nested DTO conversion.
- Use `*_dto_to_input` or `*_dto_to_{domain}` for DTO-to-application/domain conversion.
- Keep error mappings context-owned with `*_error_to_response`, `*_error_to_status_*`, or `*_error_to_message`.
- Keep handler and route names axum-oriented with `*_handler` and `*_routes`.

## Tests

Two kinds of backend tests:

- Unit tests are inline under `#[cfg(test)] mod tests` in domain and app modules, using mocked repositories.
- Integration tests in `backend/tests/` drive the real Axum router against an isolated Postgres provisioned per-test by `#[sqlx::test]`.

Run everything:

```bash
cd backend && cargo test
```

or:

```bash
just test-backend
```

See [testing.md](testing.md) for the integration test harness, coverage
workflow, and the keep/delete bar for unit tests.
