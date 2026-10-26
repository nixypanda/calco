# Backend

## Overview

The backend is a Rust service built with axum and sqlx. The code is organized by bounded context first, then by layer:

```text
backend/src/
  lib.rs                 # AppState, build_app_state, build_router
  auth/
    domain.rs
    application/
      api_key.rs
      ...
    infrastructure/postgres/
      api_key_repository.rs
      ...
    interfaces/http.rs
  import/
    domain.rs
    application.rs
    infrastructure/postgres.rs
    interfaces/http.rs
  nutrition/
    domain/
      calculation.rs     # Quantity, CalculatedNutrition, NutritionCalculator
      error.rs           # NutritionError
      units.rs           # UnitConverter
      catalog.rs
      diary_preferences.rs
      goal_target.rs
      meal.rs
      food_log.rs
    application/
      diary_preferences.rs
      goal_target.rs
      meal.rs
      food_log/
    infrastructure/postgres/
      catalog.rs
      diary_preferences.rs
      goal_target.rs
      meal.rs
      food_log.rs
    interfaces/http/
      mod.rs             # NutritionError -> IntoResponse, error_response, internal_error
      catalog.rs
      diary_preferences.rs
      goal_target.rs
      meal.rs
      food_log.rs
```

`AppState` is the app-wide composition root and lives in `lib.rs`. The
`ReadUser` and `WriteUser` extractors live in `auth/interfaces/http.rs` and are
used by nutrition handlers — auth is a foundational dependency of nutrition, not
the other way around.

## DDD Decisions

### Layering

The backend follows this dependency direction:

```text
interfaces/http -> application -> domain
infrastructure/postgres -> domain ports
```

Repository traits are defined in `domain`. PostgreSQL repositories implement
them. The application layer composes domain operations and repositories into
use cases without issuing SQL. Shared domain error enums currently contain
`sqlx::Error` variants, so persistence is not yet fully absent from domain
types; avoid extending that coupling.

### Repository Ports

Repositories are persistence and query ports, not business-action services. Domain and application code owns business decisions and state transitions, then hands already-decided state to the repository.

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

The auth credential repositories are a narrowly scoped exception for atomic
credential lifecycle operations. `ApiKeyRepository::create_if_active_count_below`,
`ApiKeyRepository::update_last_used_at_before`,
`ApiKeyRepository::update_revoked_at_if_null`, and
`SessionRepository::update_last_seen_at_before` are storage-shaped conditional
inserts and updates that keep the 10-key cap, revocation, and heartbeats
race-safe. They remain persistence operations, not business-action services, and
must not be used as precedent for normal repositories.

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
  with an empty item list.
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

### Aggregate Roots

Current aggregate roots:

- `Identity`, `UserProfile`, `Session`, and `ApiKey` for auth.
- `Product` for catalog foods.
- `FoodLog` for logged entries and nutrient snapshots.
- `Meal` for reusable user-defined meals.
- `GoalTarget` for user calorie and macro targets effective from a local date.
- `DiaryPreferences` for a user's enabled diary meal slots.
- `ImportJob` for staging and committing external catalog data.

Owned child values:

- `ProductNutrient` and `ProductServing` belong to `Product`.
- `FoodLogNutrientSnapshot` belongs to `FoodLog`.
- `MealComponent` belongs to `Meal`.
- `EnabledMealSlots` belongs to `DiaryPreferences`.
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
   form. Authenticate through `ApiKeyService`. Do not fall back to a cookie.
   Require a normal user role, an active identity, and a profile. Enforce the
   scope shown above.
2. Otherwise, use the existing browser session path.

An invalid bearer key returns `401 invalid_api_key`. A valid key with
insufficient scope returns `403 insufficient_scope`. `SessionUser` always uses
the browser session path and ignores `Authorization`; API keys cannot
authenticate key-management or assistant routes. `AuthAdmin` remains cookie-only
and likewise ignores `Authorization`.

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

- A user may have at most 10 active keys. Active means not revoked, not expired,
  and matching the current security stamp.
- Optional expiry is stored as `expires_at`. An expired key fails
  authentication.
- Revocation marks `revoked_at` immediately; there is no rotation endpoint.
  Create a replacement and revoke the old key.
- Admin password resets rotate the identity security stamp, invalidating all
  existing keys. Self-service password change is planned, not implemented.
- Disabling an identity rotates the security stamp and invalidates keys.
  Re-enabling does not restore old keys because the stamp is not reset back.
- `last_used_at` is refreshed with a conditional atomic update at most once per
  60 seconds. A failed metadata write is ignored and does not fail
  authentication, so the timestamp can remain stale.

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
| `409` | `api_key_limit_reached` | The identity already has 10 active keys. |
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
- `AUTHORIZATION` is included in the allowed CORS headers. This permits trusted
  tools to send bearer tokens; it does not make embedded browser secrets safe.
- Raw tokens are never logged or returned outside the create response.

> **Warning:** `CORS_ALLOWED_ORIGINS` is a credential-minting trust boundary.
> When it is non-empty, the backend enables credentialed CORS for exactly those
> origins. Any listed origin can use a signed-in user's session cookie to call
> the cookie-authenticated key-management route and read the raw token from the
> create response. List only first-party origins you control; never add
> third-party or untrusted origins.

## HTTP Routes

All routes are mounted under `/api`.

### Health

```text
GET /health
GET /version
```

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

Use the same date for `from` and `to` for a single-day view. Log reads and
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
- Logs: `food_logs`, `food_log_nutrients`
- Meals: `meals`, `meal_components`
- Goals: `goal_target_versions`
- Diary preferences: `diary_preferences`
- Imports: `imports`, `staging_products`, `staging_product_nutrients`, `staging_product_servings`, `import_errors`

Search uses PostgreSQL full-text search and trigram indexes.

## Database Naming Conventions

PostgreSQL adapter names should keep persistence-specific concepts visible without leaking them into application or domain layers.

Type suffixes:

- `Postgres*Repository`: public repository adapter implementing an application port.
- `*Row`: private `sqlx::FromRow` query result type.

Function naming rules:

- Keep pure row-to-domain conversions as free functions, not repository methods.
- Use `{row_type}_row_to_{domain_type}` for row-to-domain conversion helpers, for example `product_row_to_product`.
- Use context-owned names when the row type is context-specific, for example `import_error_row_to_record`.
- Keep repository `impl` blocks focused on repository behavior, SQL execution, transactions, and data-loading helpers.
- Keep insert/update helpers outside repository `impl` blocks when they are shared by multiple repository methods or only need a transaction.

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

- Unit tests are inline under `#[cfg(test)] mod tests` in domain and application modules, using mocked repositories.
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
