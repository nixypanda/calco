# Architecture

## System Overview

CalCo is a monorepo with a Rust API, React frontend, PostgreSQL database, and Python import tooling.

```text
React/Vite frontend
  -> HTTP JSON under /api
Rust axum backend
  -> sqlx
PostgreSQL

tools/importers
  -> import API
```

The backend runs database migrations on startup from `backend/src/infrastructure/postgres/migrations`.

## Product Boundaries

CalCo is a simple food tracker:

- Track foods and meals for a selected day.
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
infrastructure/postgres -> application ports -> domain
```

The domain layer owns business concepts and invariants. It does not depend on HTTP, JSON DTOs, sqlx, or PostgreSQL. The application layer owns use cases and repository ports. Infrastructure implements those ports. HTTP handlers translate request/response DTOs into application inputs and outputs.

## Bounded Contexts

### Auth

Auth separates login identity from application user ownership:

- `Identity`: username, password hash, role, status.
- `UserProfile`: application user identity; food data uses `user_profiles.id`.
- `Session`: server-managed browser session with hashed token storage.

Admin identities are for account recovery and import operations. They do not own food logs, custom foods, or meals.

### Catalog

Catalog owns products, product nutrients, product servings, canonical nutrients, and units.

`Product` is an aggregate root. `ProductNutrient` and `ProductServing` are owned child values. They are replaced through product create/update flows, not independently managed as standalone resources.

Product source fields are part of the core model:

- `source`
- `source_id`
- `visibility`
- `user_id`

This lets imported global foods and user-private custom foods share one catalog model.

### Nutrition

Nutrition calculation is a domain service:

```text
amount = amount_per_100g * grams / 100
```

Mass unit conversion is data-driven from `units.canonical_grams` and loaded into `UnitConverter`. Non-mass units such as servings and cups require product- or meal-specific serving definitions.

### Food Logging

`FoodLog` is an aggregate root owned by a user profile. It records:

- logged timestamp
- meal slot
- logged item
- quantity
- notes
- nutrient snapshots

The key invariant is historical stability: logs store calculated nutrient snapshots at log time. Summaries aggregate snapshots, not current product data.

`LoggedItem` supports products and meals:

```text
LoggedItem::Product(ProductId)
LoggedItem::Meal(MealId)
```

### Meals

`Meal` is a user-owned aggregate root. `MealComponent` values are edited through the meal aggregate. Current meal components are product-only, which avoids recursive meal definitions.

Meal nutrition is calculated from current component products when previewing or logging. When a meal is logged, the resulting nutrients are snapshotted into the food log.

### Imports

Imports are an anti-corruption/staging layer around external food datasets.

`ImportJob` owns staged products, nutrients, servings, and row-level errors. Staged rows become catalog data only when an import is committed.

Imports are intentionally operated from CLI scripts in `tools/importers`, not from browser UI.

## Transaction And Consistency Decisions

- Product create/update replaces nutrients and servings atomically.
- Food log create/update writes the log and nutrient snapshots together.
- Meal create/update replaces components atomically.
- Import commit is a batch database transaction that upserts products, nutrients, and servings.
- Summary reads aggregate `food_log_nutrients`, never live catalog nutrients.

Known accepted consistency risks are tracked in [known issues](known_issues.md).

## API Surface

All app routes are mounted under `/api`.

Major route groups:

- `/auth/*`
- `/admin/users/*`
- `/foods/*`
- `/nutrients`
- `/units`
- `/logs`
- `/summary`
- `/meals`
- `/imports`

See [backend.md](backend.md) for route details.
