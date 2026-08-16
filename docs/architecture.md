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

## Bounded Contexts

Three bounded contexts: `auth`, `nutrition`, and `import`. Each lives under its own top-level module (`backend/src/{auth,nutrition,import}/`). `auth` and `import` nest the four layers (`domain`, `application`, `infrastructure`, `interfaces`) directly. `nutrition` is organized feature-first (see below): one folder per sub-context, each nesting the four layers inside.

Dependency direction between contexts:

```text
import -> nutrition -> auth
```

`auth` depends on nothing. `nutrition` depends on `auth` only at the interface edge (its HTTP handlers use the `AuthUser` extractor), never in domain or application. `import` depends on `nutrition` only through the catalog domain (`catalog::Category`). Contexts integrate at the seams, not through shared domain logic — this is the invariant that keeps the top level clean.

### Auth

Auth separates login identity from application user ownership:

- `Identity`: username, password hash, role, status.
- `UserProfile`: application user identity; food data uses `user_profiles.id`.
- `Session`: server-managed browser session with hashed token storage.

Admin identities are for account recovery and import operations. They do not own food logs, custom foods, or meals.

### Nutrition

Nutrition is one bounded context with five aggregate roots:

- `Product` (catalog): owns `ProductNutrient` and `ProductServing` as child values. Imported global foods and user-private custom foods share this model via `source`, `source_id`, `visibility`, and `user_id`.
- `Meal`: user-owned. `MealComponent` values are edited through the aggregate; current components are product-only (no recursive meals). Nutrition is calculated from current components when previewing or logging.
- `FoodLog`: user-owned. Records timestamp, meal slot, logged item, quantity, notes, and nutrient snapshots. `LoggedItem` supports `Product(ProductId)` and `Meal(MealId)`.
- `GoalTarget`: user-owned. Stores calorie and macro targets effective from a local date, so diary views can resolve the latest saved target for any selected day while falling back to defaults if no saved row exists.
- `DiaryPreferences`: user-owned. Stores the enabled meal slots that shape the
  diary while ensuring at least one known slot remains enabled.

These aggregates share one error type (`NutritionError`) and depend on each other directly via repositories — they are not separate contexts. The shared ubiquitous language ("nutrient", "quantity", "unit"), shared lifecycle, and lack of concept translation at the seams motivated unifying them.

Within the context, the aggregates are organized feature-first: one folder per sub-context (`catalog`, `meal`, `food_log`, `guidance`, `diary`, `goals`), each nesting the four layers inside. `catalog` holds the shared kernel (`units`, `calculation`) in its domain layer; `NutritionError` and the shared HTTP glue live at the nutrition root (`error.rs`, `interfaces.rs`). The composition root stays in `nutrition/module.rs`. Their dependency direction is a DAG rooted at the catalog kernel:

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

Edges are forced by the domain: `meal` and `food_log` both need catalog's `ProductRepository` and `UnitConverter`; `food_log` depends on `meal` (a `LoggedItem::Meal` resolves a saved meal into a food-log snapshot), never the reverse; `guidance` reads food logs and overlays its own nutrient guidance. `diary` and `goals` are standalone. A sub-module holds handles to the modules below it (typically the minimal repo port it uses), never above — so the internal graph stays acyclic.

Supporting domain pieces, all in `catalog/domain/` (the shared kernel), except the error at the nutrition root:

- `calculation.rs` — `Quantity`, `CalculatedNutrition`, and the `NutritionCalculator` service (`amount = amount_per_100g * grams / 100`).
- `units.rs` — `UnitConverter`, data-driven from `units.canonical_grams`. Non-mass units (servings, cups) require product- or meal-specific serving definitions.
- `error.rs` (at `nutrition/`) — `NutritionError`.

The key data-integrity invariant is historical stability: `FoodLog` stores calculated nutrient snapshots at log time. Summaries aggregate snapshots, not current product data.

### Import

Imports are an anti-corruption/staging layer around external food datasets.

`ImportJob` owns staged products, nutrients, servings, and row-level errors. Staged rows become catalog data only when an import is committed. Imports translate at the seam (their own `ImportError`, their own DTOs) and are intentionally operated from CLI scripts in `tools/importers/data-sources`, not from browser UI.

## Transaction And Consistency Decisions

- Product create/update replaces nutrients and servings atomically.
- Food log create/update writes the log and nutrient snapshots together.
- Meal create/update replaces components atomically.
- Goal target save upserts the current local day's version for a user.
- Import commit is a batch database transaction that upserts products, nutrients, and servings.
- Summary reads aggregate `food_log_nutrients`, never live catalog nutrients.
- Food-log writes are transactional. Food-log reads load headers and nutrient
  snapshots separately, so a concurrent update could theoretically produce a
  mixed read. This is an accepted tradeoff for the current homelab scale.

## API Surface

All app routes are mounted under `/api`.

Major route groups:

- `/auth/*`
- `/admin/users/*`
- `/foods/*`
- `/nutrients`
- `/units`
- `/logs`
- `/goal`
- `/diary-preferences`
- `/meals`
- `/imports`

See [backend.md](backend.md) for route details.
