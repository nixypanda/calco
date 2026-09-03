# Backend

## Overview

The backend is a Rust service built with axum and sqlx. The code is organized by bounded context first, then by layer:

```text
backend/src/
  lib.rs                 # AppState, build_app_state, build_router
  auth/
    domain.rs
    application.rs
    infrastructure/postgres.rs
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

`AppState` is the app-wide composition root and lives in `lib.rs`. The `AuthUser` extractor lives in `auth/interfaces/http.rs` and is used by nutrition handlers — auth is a foundational dependency of nutrition, not the other way around.

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

The import repository is an explicit exception for now because imports are primarily an infrastructure and data-ingestion workflow. Do not use import repository patterns as precedent for normal domain repositories.

## API Design Notes

These notes capture endpoint choices surfaced during feature mapping.

### Consolidated Endpoints

- Food detail uses `GET /foods/{id}` and includes product nutrients and
  servings. Do not add separate public `GET /foods/{id}/nutrients` or
  `GET /foods/{id}/servings` endpoints unless partial loading becomes necessary.
- Log history uses `GET /logs?log_date=YYYY-MM-DD` for a single-day view. Do not
  add a separate `GET /logs/day/{date}` endpoint.
- Nutrition summaries use
  `GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...`. Use the same date for
  `from` and `to` for daily totals. Omit `codes` to return all tracked
  nutrients.
- Goal targets use `GET /goal?date=YYYY-MM-DD` to resolve the effective targets
  for a selected day and `PUT /goal` to create or overwrite the current day's
  saved targets.
- Diary preferences use `GET /diary-preferences` and
  `PUT /diary-preferences` to read or replace a user's enabled meal slots.
- Meals use aggregate-shaped endpoints: `POST /meals`, `GET /meals`,
  `GET /meals/{id}`, `PUT /meals/{id}`, `DELETE /meals/{id}`, and
  `GET /meals/{id}/nutrients?quantity=&unit=`.
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

- `Identity`, `UserProfile`, and `Session` for auth.
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

Normal food-tracking data is keyed by `user_profiles.id`, not `identities.id`. Admin identities exist for account recovery and import operations and do not satisfy normal user extractors.

### Imports As Anti-Corruption Layer

External datasets are converted into a normalized staging format before they reach the catalog. The import module validates rows, records row-level errors, and commits staged rows into catalog tables.

CLI scripts are the operational interface for imports. Browser import UI is intentionally out of scope.

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

Food detail includes product nutrients and servings. There are no separate public nutrient/serving detail endpoints.

### Logs And Summaries

```text
POST   /logs
POST   /logs/batch
POST   /logs/last-used
GET    /logs/recent-items?from_date=&to_date=&meal_slot=
GET    /logs/latest-slots?before=&lookback_days=
GET    /logs/{id}
GET    /logs?log_date=YYYY-MM-DD
PUT    /logs/{id}
DELETE /logs/{id}
GET    /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...
```

Use the same date for `from` and `to` for a single-day view.

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

### Meals

```text
POST   /meals
GET    /meals
GET    /meals/{id}
PUT    /meals/{id}
DELETE /meals/{id}
GET    /meals/{id}/nutrients?quantity=&unit=
```

Meal requests are aggregate-shaped. There are no standalone meal-component mutation routes.

### Goals

```text
GET /goal?date=YYYY-MM-DD
PUT /goal
```

`GET /goal` resolves the target snapshot effective for the requested local date.

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
known slot must remain enabled.

### Imports

Admin-only:

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

Authenticated user routes:

```text
GET  /api/ai/food-assistant/status
POST /api/ai/custom-food/draft
```

`GET /api/ai/food-assistant/status` returns whether text drafting is enabled and always
reports `supports_images: false` for this API version.

`POST /api/ai/custom-food/draft` accepts `multipart/form-data` with exactly one
non-file `conversation` field. Its JSON value is `{ "turns": [...] }`, with a
non-empty array of at most 20 `{ role, text }` turns. Roles are `user` or
`assistant`, and each trimmed text value is limited to 4,000 characters. The
body is limited to 96 KiB. Unknown fields, duplicate conversation fields, and
the reserved `photos` field are rejected. The response is either
`needs_clarification` with an assistant message or `draft_ready` with a complete
reviewable custom-food draft and warnings.

The route does not create or update catalog data. Clients explicitly submit an
accepted draft through `POST /api/foods/custom`. Photo inputs are not accepted in
this text-only slice. Per-user throttling and the global in-flight limit return
`429` with `Retry-After`; disabled AI returns `503`, and provider failures are
mapped to opaque `502` responses.

## Database

Migrations live in:

```text
backend/migrations
```

Run migrations explicitly with:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-migrate
```

Important tables:

- Auth: `identities`, `user_profiles`, `sessions`, `auth_audit_events`
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
nix develop -c just backend-test
```

See [testing.md](testing.md) for the integration test harness, nextest, and coverage workflow.
