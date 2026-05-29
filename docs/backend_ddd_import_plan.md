# Backend DDD Design Plan

## Summary

Build the backend as a pragmatic DDD-style Rust service using `axum`, `sqlx`, and PostgreSQL.

Current backend scope excludes bulk imports. The first milestone is the core tracking loop:

```text
Create/select food -> log quantity -> snapshot nutrients -> query daily totals
```

Initial bounded contexts:

- Catalog
- Nutrition
- Logging

Deferred contexts:

- Import
- Meals/Recipes

Auth is specified separately in `auth_design.md`. Backend ownership fields use `UserId`, which maps to `user_profiles.id`, not to authentication identity ids.

## 1. Domain Layer

The domain layer contains business concepts and rules. It must not depend on HTTP, JSON, SQLx, PostgreSQL, or framework-specific types.

Dependencies point inward:

```text
interfaces/http
    -> application
        -> domain

infrastructure/postgres
    -> application ports
    -> domain
```

### Catalog Context

The Catalog context owns foods/products, canonical nutrients, product nutrient measurements, product servings, and product visibility.

#### Product Aggregate

```text
Product aggregate
  Product entity, aggregate root
  ProductNutrient child value object
  ProductServing child value object
```

`Product` is an entity because it has identity and lifecycle. A product can be imported or manually created, updated, searched, logged, and deleted if it is a user-owned custom food.

`ProductNutrient` is a child value object because it has no independent lifecycle. It exists only as part of a `Product` and is added, replaced, or removed through the `Product` aggregate.

`ProductServing` is also a child value object for v1. It exists only as part of a `Product`; even if the database gives it an id, the domain should not treat it as independently editable.

Product aggregate fields:

```text
Product
  id: ProductId
  source: Source
  source_id: Option<SourceProductId>
  user_id: Option<UserId>
  visibility: ProductVisibility
  barcode: Option<Barcode>
  name: ProductName
  brand: Option<Brand>
  category: Option<Category>
  default_quantity: Option<Quantity>
  serving_size_g: Option<Grams>
  nutrients: Vec<ProductNutrient>
  servings: Vec<ProductServing>
  deleted_at: Option<DateTime>
```

Child value objects:

```text
ProductNutrient
  nutrient_code: NutrientCode
  amount_per_100g: AmountPer100g
  source: Option<Source>
  confidence: Option<NutrientConfidence>

ProductServing
  label: ServingLabel
  quantity: Quantity
  grams: Grams
```

Product rules:

- Catalog foods are identified by `(source, source_id)` when they come from external sources.
- User-defined foods use `source = USER`, `user_id = current user`, and `visibility = user_private`.
- Product nutrient values are stored per 100g.
- Product nutrients and servings are changed only through the `Product` aggregate.
- Deleting a custom product is a soft delete by setting `deleted_at`.
- Product search and normal lookups exclude soft-deleted products unless explicitly requested by an admin flow.
- Search visibility includes global products and the current user's private products.

#### Nutrient Reference Entity

`Nutrient` is a canonical reference entity. It is reused by products, logs, summaries, and future imports.

```text
Nutrient
  id: NutrientId
  code: NutrientCode
  name: NutrientName
  unit: UnitCode
  category: NutrientCategory
```

Nutrient rules:

- Nutrients are append-mostly canonical reference data.
- Codes must be stable after introduction.
- Do not delete or repurpose nutrient codes referenced by product or log data.
- Public user-facing APIs should not mutate nutrients in v1.

### Nutrition Context

The Nutrition context owns quantity normalization and nutrient calculation.

Value objects:

```text
Quantity
  amount: Decimal
  unit: UnitCode

Grams
  amount: Decimal

NutrientAmount
  nutrient_code: NutrientCode
  amount: Decimal
  unit: UnitCode

CalculatedNutrition
  amounts: Vec<NutrientAmount>
```

Domain services:

```text
NutritionCalculator
UnitConversionPolicy
```

Nutrition rules:

- Product nutrition calculation uses:

```text
amount = amount_per_100g * grams / 100
```

- Calculations should normalize to grams where possible.
- Unsupported units should fail with a domain error instead of guessing.

### Logging Context

The Logging context owns user food logs and immutable nutrient snapshots.

```text
FoodLog aggregate
  FoodLog entity, aggregate root
  FoodLogNutrientSnapshot child value object
```

`FoodLog` is an entity because it represents a user-created event with identity and lifecycle. Two identical lunch logs are still two separate events.

`FoodLogNutrientSnapshot` is a child value object. It is persisted separately, but its lifecycle is owned by `FoodLog`. It is created, replaced, and deleted through the log.

Food log aggregate fields:

```text
FoodLog
  id: FoodLogId
  user_id: UserId
  logged_at: LoggedAt
  meal_slot: Option<MealSlot>
  item: LoggedItem
  quantity: Quantity
  nutrient_snapshots: Vec<FoodLogNutrientSnapshot>
  notes: Option<LogNotes>

LoggedItem
  Product(ProductId)

FoodLogNutrientSnapshot
  nutrient_code: NutrientCode
  amount: NutrientAmount
```

Logging rules:

- A food log references exactly one logged item type in v1: product.
- Nutrients are snapshotted when a log is created.
- If a log is edited, snapshots are recalculated and replaced through the `FoodLog` aggregate.
- Historical summaries must use snapshot data, not current product nutrient values.

## 2. Domain Model To Database Mapping

One aggregate can map to multiple tables. A child value object having a table does not make it an independent domain entity.

### Aggregate/Table Overview

```text
Product aggregate
  products
  product_nutrients
  product_servings

Nutrient reference entity
  nutrients

FoodLog aggregate
  food_logs
  food_log_nutrients

Reference data
  units
  auth-owned user_profiles

Read model/cache
  daily_nutrition_summaries, deferred
```

### `products`

Stores the `Product` aggregate root.

```text
id                  -> ProductId
source              -> Source
source_id           -> Option<SourceProductId>
user_id             -> Option<UserId>
visibility          -> ProductVisibility
barcode             -> Option<Barcode>
name                -> ProductName
brand               -> Option<Brand>
category            -> Option<Category>
default_quantity    -> Option<Quantity.amount>
default_unit        -> Option<Quantity.unit>
serving_size_g      -> Option<Grams>
deleted_at          -> Option<DateTime>
created_at
updated_at
```

Database constraints/indexes:

- `UNIQUE (source, source_id)` for imported/catalog products.
- Barcode index.
- Source/user/category/brand indexes.
- Generated search vector and trigram indexes for search.
- Product search excludes rows where `deleted_at IS NOT NULL`.

### `product_nutrients`

Stores `ProductNutrient` child value objects owned by `Product`.

```text
product_id          -> ProductId
nutrient_id         -> NutrientId, resolved from NutrientCode
amount_per_100g     -> AmountPer100g
source              -> Option<Source>
confidence          -> Option<NutrientConfidence>
created_at
updated_at
```

Primary key:

```text
(product_id, nutrient_id)
```

Domain meaning:

- This is not an independent aggregate.
- Rows are inserted/replaced/deleted as part of product create/update flows.

### `product_servings`

Stores `ProductServing` child value objects owned by `Product`.

```text
id                  -> persistence id only in v1
product_id          -> ProductId
label               -> ServingLabel
quantity            -> Quantity.amount
unit                -> Quantity.unit
grams               -> Grams
created_at
```

Domain meaning:

- The row id is for persistence and UI convenience only.
- Product servings are not mutated independently from `Product`.

### `nutrients`

Stores canonical `Nutrient` reference entities.

```text
id                  -> NutrientId
code                -> NutrientCode
name                -> NutrientName
unit                -> UnitCode
category            -> NutrientCategory
created_at
```

Domain meaning:

- Seeded/admin-controlled reference catalog.
- Append-mostly.
- Referenced by product nutrients and food log snapshots.

### `units`

Stores canonical unit reference data.

```text
code                -> UnitCode
name
kind
```

Domain meaning:

- Reference data used by `Quantity`, `Grams`, servings, logs, and nutrient units.

### `food_logs`

Stores the `FoodLog` aggregate root.

```text
id                  -> FoodLogId
user_id             -> UserId
logged_at           -> LoggedAt
meal_slot           -> Option<MealSlot>
item_product_id     -> LoggedItem::Product(ProductId)
item_meal_id        -> deferred until Meals context exists
quantity            -> Quantity.amount
unit                -> Quantity.unit
notes               -> Option<LogNotes>
created_at
updated_at
```

Domain constraints:

- Exactly one logged item reference is set.
- In v1, only `item_product_id` is supported.

### `food_log_nutrients`

Stores `FoodLogNutrientSnapshot` child value objects owned by `FoodLog`.

```text
food_log_id         -> FoodLogId
nutrient_id         -> NutrientId, resolved from NutrientCode
amount              -> NutrientAmount.amount
unit                -> NutrientAmount.unit
```

Primary key:

```text
(food_log_id, nutrient_id)
```

Domain meaning:

- Snapshot rows are historical facts.
- They are not edited directly.
- They are created/replaced when the parent `FoodLog` is created or edited.

### `daily_nutrition_summaries`

Deferred read model/cache derived from `food_log_nutrients`.

```text
user_id             -> UserId
date
nutrient_id         -> NutrientId
amount
unit
updated_at
```

Domain meaning:

- Not an aggregate.
- Can be rebuilt from `food_logs` and `food_log_nutrients`.
- Not required for MVP.
- Add later only if direct summary aggregation is too slow.

### Auth-Owned `user_profiles`

User ownership is defined in `auth_design.md`.

```text
user_id             -> user_profiles.id
```

Application tables such as `products` and `food_logs` reference `user_profiles.id` as `UserId`. They should not reference `identities.id` directly.

## 3. Domain Model To API Mapping

The HTTP API should expose aggregate roots and read models, not child value-object tables.

Rule:

```text
Expose Product, FoodLog, Nutrient reference data, and Summary read models.
Do not expose ProductNutrient, ProductServing, or FoodLogNutrientSnapshot as standalone resources.
```

### Product APIs

Product APIs operate on the `Product` aggregate.

```text
GET    /foods/search?q=rice
GET    /foods/barcode/{barcode}
GET    /foods/{id}
POST   /foods/custom
PUT    /foods/custom/{id}
DELETE /foods/custom/{id}
```

#### `GET /foods/search?q=rice`

Maps to:

```text
Search Product aggregates by name, brand, category, and barcode.
```

Response shape:

```json
{
  "items": [
    {
      "id": "product-uuid",
      "source": "OFF",
      "source_id": "8901234567890",
      "barcode": "8901234567890",
      "name": "Amul Paneer",
      "brand": "Amul",
      "category": "Dairy",
      "serving_size_g": 100
    }
  ]
}
```

#### `GET /foods/{id}`

Maps to:

```text
Load Product aggregate.
```

Response shape:

```json
{
  "id": "product-uuid",
  "source": "OFF",
  "source_id": "8901234567890",
  "visibility": "global",
  "barcode": "8901234567890",
  "name": "Amul Paneer",
  "brand": "Amul",
  "category": "Dairy",
  "default_quantity": 100,
  "default_unit": "g",
  "serving_size_g": 100,
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount_per_100g": 296, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount_per_100g": 18.3, "unit": "g" }
  ],
  "servings": [
    { "label": "1 cube", "quantity": 1, "unit": "piece", "grams": 25 }
  ]
}
```

#### `POST /foods/custom`

Maps to:

```text
Create Product aggregate with source = USER.
```

Request shape:

```json
{
  "name": "My protein shake",
  "brand": null,
  "category": "Custom",
  "serving_size_g": 350,
  "default_quantity": 1,
  "default_unit": "serving",
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount_per_100g": 80 },
    { "code": "PROTEIN_G", "amount_per_100g": 12 },
    { "code": "CARBS_G", "amount_per_100g": 5 },
    { "code": "FAT_G", "amount_per_100g": 2 }
  ],
  "servings": [
    { "label": "1 shake", "quantity": 1, "unit": "serving", "grams": 350 }
  ]
}
```

Behavior:

- Create one `products` row.
- Create owned `product_nutrients` rows.
- Create owned `product_servings` rows if provided.
- Commit all changes atomically.

#### `PUT /foods/custom/{id}`

Maps to:

```text
Update Product aggregate owned by current user.
```

Request shape:

```json
{
  "name": "My protein shake",
  "brand": null,
  "category": "Custom",
  "serving_size_g": 350,
  "default_quantity": 1,
  "default_unit": "serving",
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount_per_100g": 82 },
    { "code": "PROTEIN_G", "amount_per_100g": 12 }
  ],
  "servings": [
    { "label": "1 shake", "quantity": 1, "unit": "serving", "grams": 350 }
  ]
}
```

Behavior:

- Only user-owned custom foods can be updated.
- Replace owned nutrients and servings through the `Product` aggregate.
- Do not mutate historical food log snapshots.

#### `DELETE /foods/custom/{id}`

Maps to:

```text
Delete user-owned custom Product aggregate.
```

Behavior:

- Only user-owned custom foods can be deleted.
- Set `products.deleted_at`.
- Exclude the product from normal search and selection.
- Existing food logs remain valid because they use nutrient snapshots.

### Nutrient APIs

Nutrient and unit APIs expose canonical reference data used by forms, validation, and calculations.

```text
GET /nutrients
GET /nutrients/{code}
GET /units
```

#### `GET /nutrients`

Response shape:

```json
{
  "items": [
    { "code": "ENERGY_KCAL", "name": "Energy", "unit": "kcal", "category": "macro" },
    { "code": "PROTEIN_G", "name": "Protein", "unit": "g", "category": "macro" }
  ]
}
```

#### `GET /nutrients/{code}`

Response shape:

```json
{
  "code": "PROTEIN_G",
  "name": "Protein",
  "unit": "g",
  "category": "macro"
}
```

No public write APIs for nutrients in v1.

#### `GET /units`

Response shape:

```json
{
  "items": [
    { "code": "g", "name": "Gram", "kind": "mass" },
    { "code": "serving", "name": "Serving", "kind": "serving" }
  ]
}
```

No public write APIs for units in v1.

### Food Log APIs

Food log APIs operate on the `FoodLog` aggregate.

```text
POST   /logs
GET    /logs/{id}
GET    /logs?from=YYYY-MM-DD&to=YYYY-MM-DD
PUT    /logs/{id}
DELETE /logs/{id}
```

#### `POST /logs`

Maps to:

```text
Create FoodLog aggregate and owned nutrient snapshots.
```

Request shape:

```json
{
  "logged_at": "2026-05-29T13:30:00+05:30",
  "meal_slot": "lunch",
  "item": {
    "type": "product",
    "id": "product-uuid"
  },
  "quantity": {
    "amount": 150,
    "unit": "g"
  },
  "notes": "Lunch"
}
```

Response shape:

```json
{
  "id": "log-uuid",
  "logged_at": "2026-05-29T13:30:00+05:30",
  "meal_slot": "lunch",
  "item": {
    "type": "product",
    "id": "product-uuid",
    "name": "Amul Paneer"
  },
  "quantity": {
    "amount": 150,
    "unit": "g"
  },
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount": 444, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount": 27.45, "unit": "g" }
  ],
  "notes": "Lunch"
}
```

Behavior:

- Load the `Product` aggregate.
- Convert the requested quantity to grams.
- Calculate nutrients.
- Insert `food_logs`.
- Insert owned `food_log_nutrients`.
- Commit all changes atomically.

#### `GET /logs/{id}`

Maps to:

```text
Load FoodLog aggregate.
```

Response shape is the same as `POST /logs`.

#### `GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD`

Maps to:

```text
Query FoodLog aggregates for one user and date range. Use the same date for `from` and `to` for a day view.
```

Response shape:

```json
{
  "from": "2026-05-29",
  "to": "2026-05-29",
  "items": [
    {
      "id": "log-uuid",
      "logged_at": "2026-05-29T13:30:00+05:30",
      "meal_slot": "lunch",
      "item": {
        "type": "product",
        "id": "product-uuid",
        "name": "Amul Paneer"
      },
      "quantity": {
        "amount": 150,
        "unit": "g"
      },
      "nutrients": [
        { "code": "ENERGY_KCAL", "amount": 444, "unit": "kcal" },
        { "code": "PROTEIN_G", "amount": 27.45, "unit": "g" }
      ],
      "notes": "Lunch"
    }
  ]
}
```

#### `PUT /logs/{id}`

Maps to:

```text
Update FoodLog aggregate.
```

Request shape:

```json
{
  "logged_at": "2026-05-29T14:00:00+05:30",
  "meal_slot": "lunch",
  "item": {
    "type": "product",
    "id": "product-uuid"
  },
  "quantity": {
    "amount": 200,
    "unit": "g"
  },
  "notes": "Late lunch"
}
```

Behavior:

- Recalculate nutrient snapshots.
- Replace owned `food_log_nutrients`.
- Update `food_logs`.
- Commit atomically.

#### `DELETE /logs/{id}`

Maps to:

```text
Delete FoodLog aggregate.
```

Behavior:

- Delete `food_logs`.
- Delete owned `food_log_nutrients` by cascade.

### Summary APIs

Summary APIs are read-model APIs derived from food log snapshots.

```text
GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=ENERGY_KCAL,PROTEIN_G
```

#### `GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=ENERGY_KCAL,PROTEIN_G`

Response shape:

```json
{
  "from": "2026-05-29",
  "to": "2026-05-29",
  "totals": [
    { "code": "ENERGY_KCAL", "amount": 2100, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount": 145, "unit": "g" },
    { "code": "CARBS_G", "amount": 230, "unit": "g" },
    { "code": "FAT_G", "amount": 70, "unit": "g" }
  ]
}
```

Behavior:

- MVP behavior aggregates directly from `food_logs` and `food_log_nutrients`.
- A later summary cache may replace this internally without changing the API.
- If `codes` is omitted, return all tracked nutrients for the range.
- Use the same date for `from` and `to` for a daily summary.
- Never recalculate from current product nutrients.

## 4. Application Layer

The application layer owns use-case orchestration, repository ports, and transaction boundaries.

Use cases:

- `SearchProducts`
- `GetProductDetail`
- `CreateCustomFood`
- `UpdateCustomFood`
- `DeleteCustomFood`
- `ListNutrients`
- `GetNutrient`
- `ListUnits`
- `LogFood`
- `GetFoodLog`
- `GetLogsForRange`
- `UpdateFoodLog`
- `DeleteFoodLog`
- `GetSummary`

Repository ports:

- `ProductRepository`
- `NutrientRepository`
- `FoodLogRepository`
- `SummaryRepository`
- `TransactionManager`

Transaction boundaries:

- Custom food create/update/delete.
- Food log create/update/delete plus snapshot replacement.

## 5. Infrastructure Layer

The infrastructure layer implements persistence, migrations, search, seed data, and database-specific behavior.

Responsibilities:

- SQLx connection pool setup.
- PostgreSQL migrations.
- Seed canonical nutrients and units.
- Repository implementations.
- Row-to-domain and domain-to-row mapping.
- PostgreSQL full-text/trigram product search.

Infrastructure-only row structs:

- `ProductRow`
- `NutrientRow`
- `ProductNutrientRow`
- `ProductServingRow`
- `FoodLogRow`
- `FoodLogNutrientRow`
- `DailyNutritionSummaryRow`

## 6. Implementation Setup

### Runtime Stack

Use:

```text
Rust
axum
tokio
serde
sqlx
PostgreSQL
rust_decimal
uuid
time or chrono
tracing
```

Use `sqlx` migrations as the source of truth for schema changes.

### Configuration

Minimum backend configuration:

```text
DATABASE_URL
APP_ENV
APP_HOST
APP_PORT
SESSION_COOKIE_NAME
SESSION_COOKIE_SECURE
SESSION_TTL_SECONDS
PASSWORD_HASH_PARAMS, optional
```

Auth-specific behavior and tables are defined in `auth_design.md`.

### Baseline Routes

Add non-domain operational routes:

```text
GET /health
GET /version
```

`GET /health` should verify the API process is alive. Database readiness can be either included directly or exposed later as a deeper readiness check.

### Migration Order

Create migrations in this order:

1. Auth tables from `auth_design.md`: `identities`, `user_profiles`, `sessions`, and auth audit events if implemented immediately.
2. PostgreSQL extensions: `pg_trgm`.
3. Reference tables: `nutrients`, `units`.
4. Catalog tables: `products`, `product_nutrients`, `product_servings`.
5. Product search generated column and indexes.
6. Logging tables: `food_logs`, `food_log_nutrients`.
7. Deferred summary cache table only when cache implementation is added.

### Seed Data

Seed canonical units and initial canonical nutrients idempotently.

Initial units:

```text
g
kg
mg
ug
ml
l
serving
piece
packet
cup
tbsp
tsp
```

Initial nutrients:

```text
ENERGY_KCAL
PROTEIN_G
CARBS_G
FAT_G
FIBER_G
SUGAR_G
SATURATED_FAT_G
TRANS_FAT_G
SODIUM_MG
CHOLESTEROL_MG
POTASSIUM_MG
```

### Foreign Key Policy

- `products.user_id` references `user_profiles.id` and is nullable for global catalog foods.
- `food_logs.user_id` references `user_profiles.id`.
- `food_log_nutrients.food_log_id` cascades on delete.
- `product_nutrients.product_id` and `product_servings.product_id` cascade on hard delete, but normal custom product deletion uses soft delete.
- `food_logs.item_product_id` should not cascade delete products. Historical logs must remain readable through snapshots even if a custom product is soft-deleted.

### MVP Unit Conversion Policy

MVP quantity-to-grams conversion rules:

- `g` is already grams.
- `kg` converts to grams.
- `mg` and `ug` are valid nutrient units, but should not be accepted as food log quantity units unless explicitly supported.
- Product-specific serving/count units such as `serving`, `piece`, `packet`, `cup`, `tbsp`, and `tsp` require a matching `ProductServing` for the selected product.
- Unsupported or ambiguous units fail validation.

### Error Shape

Use a stable JSON error shape across routes:

```json
{
  "error": {
    "code": "validation_error",
    "message": "Human readable message",
    "details": {}
  }
}
```

Domain errors should map to stable application error codes before becoming HTTP responses.

## 7. Suggested Rust Layout

```text
src/
  main.rs
  config.rs

  domain/
    catalog/
      mod.rs
      product.rs
      nutrient.rs
      serving.rs
      value_objects.rs
      policies.rs
    logging/
      mod.rs
      food_log.rs
      snapshot.rs
      meal_slot.rs
    nutrition/
      mod.rs
      calculator.rs
      quantity.rs
      unit.rs

  application/
    catalog/
      search_products.rs
      get_product.rs
      create_custom_food.rs
      update_custom_food.rs
      delete_custom_food.rs
    logging/
      log_food.rs
      get_food_log.rs
      get_logs.rs
      update_food_log.rs
      delete_food_log.rs
    summaries/
      get_summary.rs
    ports/
      product_repository.rs
      nutrient_repository.rs
      food_log_repository.rs
      summary_repository.rs
      transaction.rs

  infrastructure/
    postgres/
      mod.rs
      db.rs
      rows.rs
      product_repository.rs
      nutrient_repository.rs
      food_log_repository.rs
      summary_repository.rs
      migrations/

  interfaces/
    http/
      mod.rs
      error.rs
      state.rs
      routes/
        health.rs
        foods.rs
        nutrients.rs
        logs.rs
        summaries.rs
      dto/
        foods.rs
        nutrients.rs
        logs.rs
        summaries.rs
```

## 8. Test Plan

Domain tests:

- Quantity-to-grams conversion.
- Nutrient scaling from per-100g values.
- Unsupported unit handling.
- Product aggregate owns nutrient and serving replacement.
- FoodLog aggregate owns snapshot replacement.

Application tests:

- Custom food creation writes product, nutrients, and servings atomically.
- Custom food update replaces owned nutrients and servings.
- Food logging snapshots calculated nutrients.
- Food log update recalculates and replaces snapshots.
- Daily summary reads snapshot values.
- Editing product nutrients does not change historical summaries.

Infrastructure tests:

- Migrations apply cleanly to a fresh database.
- Seed data is idempotent.
- Product search ranking handles barcode, exact text, full-text, and trigram cases.
- Repository implementations reconstruct aggregates from normalized tables.

Interface tests:

- HTTP routes decode valid requests.
- Invalid requests return stable JSON error responses.
- Child resources are not independently mutable through public APIs.
- Domain and application errors map to appropriate status codes.

## Assumptions

- Backend stack is `axum + sqlx + PostgreSQL`.
- Imports are deferred for now.
- Meals are deferred until after product logging works.
- Images are out of scope.
- Single-user auth is acceptable for the homelab MVP.
- The database keeps `user_id` where needed for future multi-user support.
- DDD should remain pragmatic: introduce entities, value objects, and services where they protect real rules.
