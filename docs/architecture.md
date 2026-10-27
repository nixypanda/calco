# Architecture

## System Overview

CalCo is a monorepo with a Rust API, Elm web frontend, PostgreSQL database, and Python import tooling.

```text
Elm frontend-web
  -> HTTP JSON under /api
Rust axum backend
  -> sqlx
PostgreSQL

importers/data-sources/
  -> import API
importers/personal-data/
  -> user-facing APIs (foods, logs, meals)
```

Database migrations live in `backend/migrations` and are applied explicitly with `sqlx-cli`.

## Product Boundaries

CalCo is a simple food tracker:

- Track foods and meals for a selected day.
- Compare daily intake against saved calorie and macro goals.
- Preserve historical logs with nutrient snapshots.
- Keep account recovery simple through an admin identity.
- Run catalog imports from CLI scripts.

Out of current product scope:

- Trend dashboards and charts.
- Browser-based import administration.
- Offline writes or service-worker behavior.
- Native mobile app.

## DDD Shape

The backend uses pragmatic DDD boundaries without heavy ceremony.

Dependency direction:

```text
interfaces/http -> application -> domain
infrastructure/postgres -> domain ports
```

The domain layer owns business concepts, invariants, and repository ports. It
does not own HTTP or JSON DTOs. Infrastructure implements the ports, and the
application layer composes domain operations into use cases without issuing
SQL directly. The shared domain error enums currently carry `sqlx::Error`
variants as a pragmatic adapter leak; new domain behavior should not deepen
that coupling.

Repository ports remain storage-shaped.

## Bounded Contexts

Four bounded contexts: `auth`, `nutrition`, `import`, and `assistant`. Each
lives under its own top-level backend module. `auth`, `import`, and `assistant`
nest the four layers (`domain`, `application`, `infrastructure`, `interfaces`)
directly. `nutrition` is organized feature-first (see below): one folder per
sub-context, each nesting the four layers inside.

Dependency direction between contexts:

```text
import -> nutrition -> auth
assistant -> nutrition (read-only catalog vocabulary)
```

`auth` depends on nothing. `nutrition` depends on `auth` only at the interface edge (its HTTP handlers use the `ReadUser` and `WriteUser` extractors), never in domain or application. `import` depends on `nutrition` only through the catalog domain (`catalog::Category`). Contexts integrate at the seams, not through shared domain logic — this is the invariant that keeps the top level clean.

### Auth

Auth separates login identity from application user ownership:

- `Identity`: username, password hash, role, status, and a rotating security
  stamp.
- `UserProfile`: application user identity; food data uses `user_profiles.id`.
- `Session`: server-managed browser session with hashed token storage.
- `ApiKey`: personal bearer credential bound to an identity and a snapshot of
  its security stamp. Stored in `api_keys` with a SHA-256 token hash and display
  hint only; the raw token is returned once at creation.

Admin identities are for account recovery and import operations. They do not
own food logs, custom foods, or meals, and they cannot create or use personal
API keys.

Personal API keys authenticate as the owning normal user and resolve to the same
`UserProfile` as that user's browser session. They carry either `read` or
`read_write` scope, may expire, and remain subject to the existing ownership
checks. The raw token is never persisted; only its hash is stored.

Auth persistence includes the `api_keys` table. Each row carries the owning
identity, a security-stamp snapshot, name, token hash and hint, scope, and
creation, last-use, expiry, and revocation timestamps.

### Nutrition

Nutrition is one bounded context with five aggregate roots:

- `Product` (catalog): owns `ProductNutrient` and `ProductServing` as child values. Imported foods and custom foods are globally visible to authenticated users; custom-food writes remain creator-only. Both share this model via `source`, `source_id`, `visibility`, and `user_id`.
- `Meal`: creator-owned for writes and globally visible to authenticated users. `MealComponent` values are edited through the aggregate; current components are product-only (no recursive meals). Nutrition is calculated from current components when previewing or logging.
- `FoodLog`: user-owned. Records timestamp, meal slot, logged item, quantity, notes, and nutrient snapshots. `LoggedItem` supports `Product(ProductId)` and `Meal(MealId)`.
- `GoalTarget`: user-owned. Stores calorie and macro targets effective from a local date, so diary views can resolve the latest saved target for any selected day while falling back to defaults if no saved row exists.
- `DiaryPreferences`: user-owned. Stores the enabled meal slots that shape the
  diary while ensuring at least one known slot remains enabled.

These aggregates share one error type (`NutritionError`) and application-level
read ports where one nutrition sub-context needs another. They are not separate
bounded contexts: the shared ubiquitous language ("nutrient", "quantity",
"unit"), shared lifecycle, and lack of concept translation at the seams
motivated unifying them. Repository ports remain private dependencies of the
application service that owns the aggregate; an HTTP interface or downstream
sub-context never receives another aggregate's repository.

Within the context, the aggregates are organized feature-first: one folder per sub-context (`catalog`, `meal`, `food_log`, `guidance`, `diary`, `goals`), each nesting the four layers inside. `catalog` holds the shared kernel (`units`, `calculation`) in its domain layer; `NutritionError` and the shared HTTP glue live at the nutrition root (`error.rs`, `interfaces/http.rs`). The composition root stays in `nutrition/module.rs`. Their dependency direction is a DAG rooted at the catalog kernel:

```text
catalog                       (kernel — no deps)
  ^   ^
  |   |
meal  |                       meal -> catalog
  ^   |
  |   |
food_log                      food_log -> catalog, meal
  ^
  |
guidance                      guidance -> food_log
diary                         (island)
goals                         (island)
```

The concrete dependency graph is:

```text
HTTP interfaces
  -> catalog application service -> CatalogPolicy -> catalog repositories
                                 \-> ExternalProductCatalog
                                      -> OpenFoodFactsClient
  -> meal application service    -> MealPolicy    -> meal repository
                                \-> CatalogReadPort
  -> food-log application service -> FoodLogPolicy -> food-log repository
                                    -> CatalogReadPort
                                    -> MealReadPort
  -> guidance application service -> FoodLogQueryPort
                                    -> guidance repository
  -> diary application service   -> diary repository
  -> goals application service   -> goals repository
```

The cross-subcontext edges are use-case-shaped application ports:
`CatalogReadPort` resolves shared, active catalog products; `MealReadPort`
resolves a shared meal for logging after applying meal policy; and
`FoodLogQueryPort` returns actor-scoped log data for derived views such as
guidance. `UnitConverter` remains a catalog shared-kernel value. Concrete
PostgreSQL repositories are constructed only in `nutrition/module.rs`, injected
into their owning services, and are not retained by `NutritionModule` or any
HTTP-extractable submodule state.

`ExternalProductCatalog` is the catalog application's outbound port for live
barcode misses. Its `OpenFoodFactsClient` adapter is constructed in the same
composition root. The catalog service always checks PostgreSQL first, so an
existing product does not depend on external availability. A usable OFF match
is converted into the `Product` aggregate and persisted as a globally visible
`OFF` product before it is returned.

Supporting domain pieces, all in `catalog/domain/` (the shared kernel), except the error at the nutrition root:

- `calculation.rs` — `Quantity`, `CalculatedNutrition`, and the `NutritionCalculator` service (`amount = amount_per_100g * grams / 100`).
- `units.rs` — `UnitConverter`, data-driven from `units.canonical_grams`. Non-mass units (servings, cups) require product- or meal-specific serving definitions.
- `error.rs` (at `nutrition/`) — `NutritionError`.

The key data-integrity invariant is historical stability: `FoodLog` stores calculated nutrient snapshots at log time. Summaries aggregate snapshots, not current product data.

### Import

Imports are an anti-corruption/staging layer around external food datasets.

`ImportJob` owns staged products, nutrients, servings, and row-level errors. Staged rows become catalog data only when an import is committed. Imports translate at the seam (their own `ImportError`, their own DTOs) and are intentionally operated from CLI scripts in `tools/importers/data-sources`, not from browser UI.

### Assistant

The assistant is a review-before-write custom-food drafting context. It receives
a bounded conversation and optional sanitized food photos, supplies the model
with a bounded read-only nutrition vocabulary, and returns either one
clarification question or a complete food draft. It never persists catalog
data; the user must review and submit a draft through the existing custom-food
API.

Provider credentials are loaded once at startup only when AI is enabled.
Requests are authenticated, size-bounded, rate-limited per user, and protected
by a process-wide concurrency limit. Telemetry contains only user ID, latency,
outcome, and provider token counts when present. Prompt and response content,
provider configuration, credentials, and credential paths are excluded.

Image-capable providers accept bounded JPEG, PNG, and WebP multipart uploads.
The backend validates file signatures and decoded dimensions, strips metadata
by re-encoding, and sends images only with the latest user turn. The user must
still review and explicitly submit the resulting draft before any catalog write
occurs. Barcode lookup now implements the first two levels of this flow:

```text
Local barcode lookup
  -> match: open the catalog food
  -> miss: query Open Food Facts
       -> match: normalize and persist the product, then open it for logging
       -> miss: offer custom-food creation
            -> planned: photograph nutrition table -> review draft -> create
```

The live OFF path accepts numeric barcodes from 4 to 24 digits, bounds the
response to 1 MiB, and requires a usable product name. It maps supported
per-100 g nutrients into CalCo's nutrient catalog, normalizes up to 30 category
tags, and creates a `serving` conversion/default only when OFF provides a
positive gram serving such as `15 g`. Unsupported or malformed nutrient values
are omitted rather than guessed.

Custom foods store nutrition per 100 g and may define ordered, food-specific
serving conversions. An optional default portion is only a logging-form prefill:
it is either a gram quantity or a quantity using a configured serving unit.

## Transaction And Consistency Decisions

- Product create/update replaces nutrients and servings atomically.
- Food log create/update writes the log and nutrient snapshots together.
- Meal create/update replaces components atomically.
- Goal target save upserts the current local day's version for a user.
- Import commit is a batch database transaction that upserts products, nutrients, and servings.
- A successful live OFF barcode miss is persisted before the response is
  returned. Concurrent first scans can still race on the external source key;
  this is an accepted homelab-scale tradeoff until an atomic create-or-load is
  needed.
- Summary reads aggregate `food_log_nutrients`, never live catalog nutrients.
- Food-log writes are transactional. Food-log reads load headers and nutrient
  snapshots separately, so a concurrent update could theoretically produce a
  mixed read. This is an accepted tradeoff for the current homelab scale.
- API-key `last_used_at` is refreshed best-effort and application-throttled to
  roughly once per 60 seconds. A failed metadata write does not fail
  authentication, and the value can remain stale. Concurrent requests may both
  refresh the timestamp.
- Browser-session `last_seen_at` is refreshed best-effort at roughly 60-second
  intervals. Failed updates are ignored, and a stale heartbeat cannot clear a
  concurrent logout's revocation.
- The 10-active-key cap is a best-effort application-level limit, not a
  database-enforced invariant. Concurrent creates can leave an account with more
  than 10 active keys, and the overage persists until a key is revoked or
  expires. This is an accepted homelab-scale tradeoff.

## API Surface

All app routes are mounted under `/api`.

Normal user-data routes accept either the browser session cookie or a personal
API key through `Authorization: Bearer`. Key-management routes
(`/auth/api-keys`), the assistant, and admin/import routes require a browser
session cookie. Admin and import routes also require an admin session.

Major route groups:

- `/auth/*`
- `/auth/api-keys` (browser session only)
- `/admin/users/*`
- `/foods/*`
- `/nutrients`
- `/units`
- `/logs`
- `/nutrition/*`
- `/goal`
- `/diary-preferences`
- `/meals`
- `/imports`
- `/ai/food-assistant/status`
- `/ai/custom-food/draft`

See [backend.md](backend.md) for route details.
