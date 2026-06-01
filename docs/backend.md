# Backend

## Overview

The backend is a Rust service built with axum and sqlx. The code is organized by layer and context:

```text
backend/src/
  domain/
    auth.rs
    catalog.rs
    food_log.rs
    import.rs
    meal.rs
    nutrition.rs
    units.rs
  application/
    auth.rs
    catalog.rs
    food_log.rs
    import.rs
    meal.rs
  infrastructure/postgres/
    auth.rs
    catalog.rs
    food_log.rs
    import.rs
    meal.rs
  interfaces/http/
    auth.rs
    catalog.rs
    food_log.rs
    import.rs
    meal.rs
```

## DDD Decisions

### Layering

The backend follows this dependency direction:

```text
interfaces/http -> application -> domain
infrastructure/postgres -> application ports -> domain
```

The application layer defines repository traits. PostgreSQL repositories implement those traits. This keeps use cases independent of sqlx and keeps domain types independent of persistence concerns.

### Aggregate Roots

Current aggregate roots:

- `Identity`, `UserProfile`, and `Session` for auth.
- `Product` for catalog foods.
- `FoodLog` for logged entries and nutrient snapshots.
- `Meal` for reusable user-defined meals.
- `ImportJob` for staging and committing external catalog data.

Owned child values:

- `ProductNutrient` and `ProductServing` belong to `Product`.
- `FoodLogNutrientSnapshot` belongs to `FoodLog`.
- `MealComponent` belongs to `Meal`.
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
GET    /logs/{id}
GET    /logs?from=YYYY-MM-DD&to=YYYY-MM-DD
PUT    /logs/{id}
DELETE /logs/{id}
GET    /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...
```

Use the same date for `from` and `to` for a single-day view.

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

## Database

Migrations live in:

```text
backend/migrations
```

Run migrations explicitly with:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just backend-migrate
```

Important tables:

- Auth: `identities`, `user_profiles`, `sessions`, `auth_audit_events`
- Catalog: `products`, `product_nutrients`, `product_servings`, `nutrients`, `units`
- Logs: `food_logs`, `food_log_nutrients`
- Meals: `meals`, `meal_components`
- Imports: `imports`, `staging_products`, `staging_product_nutrients`, `staging_product_servings`, `import_errors`

Search uses PostgreSQL full-text search and trigram indexes.

## Database Naming Conventions

PostgreSQL adapter names should keep persistence-specific concepts visible without leaking them into application or domain layers.

Type suffixes:

- `Postgres*Repository`: public repository adapter implementing an application port.
- `*Row`: private `sqlx::FromRow` query result type.
- `*LookupRow`: private row type used by a repository when implementing a lookup port for another context.

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

Backend tests are inline under `#[cfg(test)] mod tests`.

Run:

```bash
cd backend && cargo test
```

or:

```bash
just backend-test
```
