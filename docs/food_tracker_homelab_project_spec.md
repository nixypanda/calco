# Food & Nutrition Tracker — Homelab Project Specification

## Status Note

This is the original high-level project specification. For backend implementation, prefer the newer focused design documents when details differ:

- `backend_ddd_import_plan.md` for MVP backend domain, database, API, and infrastructure setup.
- `backend_next_later_design.md` for meals, imports, goals, corrections, and other non-MVP backend implications.
- `auth_design.md` for username/password auth, sessions, bootstrap admin, and user profiles.
- `features.md` for feature stories and consolidated API mapping notes.

## Goal

Build a self-hosted food and nutrition tracking system using:

- PostgreSQL as the primary database
- Rust backend API
- Progressive Web App frontend
- Bulk ingestion interface for external food datasets such as Open Food Facts, USDA, IFCT, and other national food composition tables

The first version should support:

- Calorie tracking
- Macro tracking
- Historical nutrition logs
- Custom foods/meals entered directly with nutrient data
- Custom meals/recipes created from products and other custom meals
- Bulk ingestion through controlled API/file interfaces, not direct database writes
- PWA usage on iOS through Safari “Add to Home Screen”

Images are explicitly out of scope for the initial homelab version.

---

## High-Level Architecture

```text
PWA Frontend
    ↓ HTTPS/JSON
Rust Backend API
    ↓ SQL
PostgreSQL
    ↑
Bulk Import Scripts / Import Jobs
```

Recommended backend stack:

```text
Rust
axum or actix-web
sqlx or diesel
serde
tokio
utoipa or aide for OpenAPI
```

Recommended frontend stack:

```text
Progressive Web App
TypeScript
React / Solid / Svelte / Vue
Vite
Service Worker
IndexedDB for small offline cache
Web App Manifest
```

Recommended database:

```text
PostgreSQL
pg_trgm
Generated tsvector search column
Optional TimescaleDB later, not needed initially
```

---

## Core Domain Areas

```text
Food catalog
Nutrient definitions
Long-form nutrient values
Product servings and unit conversions
User-defined foods
User-defined meals/recipes
Food logs
Historical nutrient snapshots
Daily summaries
Bulk ingestion
Search
```

---

## Key Design Decisions

Use:

- Long-form nutrient values, not wide nutrient columns
- Snapshot logged nutrients when a food is logged
- Products with source/user ownership
- Meals as composable recipes
- Bulk imports through staging/upsert workflows
- PostgreSQL full-text search and trigram indexes
- PWA frontend instead of native app initially

Avoid initially:

- Wide nutrient columns
- Direct DB access for user import scripts
- Recalculating old logs from current product data
- Microservices
- Elasticsearch
- TimescaleDB
- Image storage
- Native iOS app development

---

## Data Model

### `users`

For a homelab single-user setup, this can be minimal. Still model it explicitly so the system can later support multiple users.

```sql
CREATE TABLE users (
  id uuid PRIMARY KEY,
  email text UNIQUE,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
```

---

### `products`

Represents an atomic food/product/catalog item.

Examples:

- USDA raw rice
- Open Food Facts packaged paneer
- IFCT cooked dal
- User-entered protein shake

```sql
CREATE TABLE products (
  id uuid PRIMARY KEY,

  source text NOT NULL,              -- USDA, OFF, IFCT, USER, etc.
  source_id text,
  user_id uuid REFERENCES users(id), -- NULL for global catalog items

  visibility text NOT NULL DEFAULT 'global', -- global, user_private

  barcode text,
  name text NOT NULL,
  brand text,
  category text,

  default_quantity numeric,
  default_unit text,
  serving_size_g numeric,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (source, source_id)
);
```

Recommended indexes:

```sql
CREATE INDEX products_barcode_idx ON products (barcode);
CREATE INDEX products_source_idx ON products (source);
CREATE INDEX products_user_id_idx ON products (user_id);
CREATE INDEX products_brand_idx ON products (brand);
CREATE INDEX products_category_idx ON products (category);
```

---

### Product Search

Enable PostgreSQL search extensions:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

Add generated search vector:

```sql
ALTER TABLE products
ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
  to_tsvector(
    'simple',
    coalesce(name, '') || ' ' ||
    coalesce(brand, '') || ' ' ||
    coalesce(category, '') || ' ' ||
    coalesce(barcode, '')
  )
) STORED;
```

Indexes:

```sql
CREATE INDEX products_search_vector_idx
ON products USING GIN (search_vector);

CREATE INDEX products_name_trgm_idx
ON products USING GIN (name gin_trgm_ops);

CREATE INDEX products_brand_trgm_idx
ON products USING GIN (brand gin_trgm_ops);
```

---

### `nutrients`

Canonical nutrient definitions.

```sql
CREATE TABLE nutrients (
  id uuid PRIMARY KEY,
  code text UNIQUE NOT NULL,     -- ENERGY_KCAL, PROTEIN_G, FAT_G, etc.
  name text NOT NULL,
  unit text NOT NULL,            -- kcal, g, mg, ug
  category text,                 -- macro, vitamin, mineral, amino_acid, etc.
  created_at timestamptz NOT NULL DEFAULT now()
);
```

Initial required nutrients:

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

---

### `product_nutrients`

Long-form nutrient measurements.

```sql
CREATE TABLE product_nutrients (
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  nutrient_id uuid NOT NULL REFERENCES nutrients(id),

  amount_per_100g numeric NOT NULL,

  source text,
  confidence text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (product_id, nutrient_id)
);
```

Indexes:

```sql
CREATE INDEX product_nutrients_nutrient_id_idx
ON product_nutrients (nutrient_id);
```

Calculation rule:

```text
nutrient_amount = amount_per_100g * quantity_in_grams / 100
```

---

### `units`

Canonical units.

```sql
CREATE TABLE units (
  code text PRIMARY KEY,      -- g, kg, ml, l, serving, piece
  name text NOT NULL,
  kind text NOT NULL          -- mass, volume, count, serving
);
```

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

Internally, nutrition calculations should prefer grams where possible.

---

### `product_servings`

Product-specific serving conversions.

Examples:

```text
1 scoop = 30g
1 packet = 75g
1 cup cooked rice = 158g
```

```sql
CREATE TABLE product_servings (
  id uuid PRIMARY KEY,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,

  label text NOT NULL,
  quantity numeric NOT NULL,
  unit text NOT NULL,
  grams numeric NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now()
);
```

Index:

```sql
CREATE INDEX product_servings_product_id_idx
ON product_servings (product_id);
```

---

## Custom Foods

Direct custom food with nutrient data should be stored as a `products` row with:

```text
source = USER
user_id = current user
visibility = user_private
```

Its nutrients should be stored in `product_nutrients` exactly like catalog foods.

This avoids having a separate custom-food model.

---

## Meals / Recipes

Meals are composite foods made from products and/or other meals.

### `meals`

```sql
CREATE TABLE meals (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),

  name text NOT NULL,
  notes text,

  total_quantity numeric,
  total_unit text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
```

---

### `meal_components`

A component can be either a product or another meal.

```sql
CREATE TABLE meal_components (
  id uuid PRIMARY KEY,
  meal_id uuid NOT NULL REFERENCES meals(id) ON DELETE CASCADE,

  component_product_id uuid REFERENCES products(id),
  component_meal_id uuid REFERENCES meals(id),

  quantity numeric NOT NULL,
  unit text NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),

  CHECK (
    (component_product_id IS NOT NULL AND component_meal_id IS NULL)
    OR
    (component_product_id IS NULL AND component_meal_id IS NOT NULL)
  )
);
```

Indexes:

```sql
CREATE INDEX meal_components_meal_id_idx
ON meal_components (meal_id);

CREATE INDEX meal_components_component_product_id_idx
ON meal_components (component_product_id);

CREATE INDEX meal_components_component_meal_id_idx
ON meal_components (component_meal_id);
```

Backend must prevent meal cycles.

Invalid example:

```text
Meal A includes Meal B
Meal B includes Meal A
```

---

## Food Logs

### `food_logs`

Represents a user logging a product or meal at a time.

```sql
CREATE TABLE food_logs (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id),

  logged_at timestamptz NOT NULL,
  meal_slot text, -- breakfast, lunch, dinner, snack

  item_product_id uuid REFERENCES products(id),
  item_meal_id uuid REFERENCES meals(id),

  quantity numeric NOT NULL,
  unit text NOT NULL,

  notes text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CHECK (
    (item_product_id IS NOT NULL AND item_meal_id IS NULL)
    OR
    (item_product_id IS NULL AND item_meal_id IS NOT NULL)
  )
);
```

Indexes:

```sql
CREATE INDEX food_logs_user_logged_at_idx
ON food_logs (user_id, logged_at);

CREATE INDEX food_logs_user_meal_slot_logged_at_idx
ON food_logs (user_id, meal_slot, logged_at);
```

---

### `food_log_nutrients`

Snapshot nutrient values at the time of logging.

This prevents historical data from changing when catalog data is later updated.

```sql
CREATE TABLE food_log_nutrients (
  food_log_id uuid NOT NULL REFERENCES food_logs(id) ON DELETE CASCADE,
  nutrient_id uuid NOT NULL REFERENCES nutrients(id),

  amount numeric NOT NULL,
  unit text NOT NULL,

  PRIMARY KEY (food_log_id, nutrient_id)
);
```

Indexes:

```sql
CREATE INDEX food_log_nutrients_nutrient_id_idx
ON food_log_nutrients (nutrient_id);
```

---

## Daily Summary Cache

Optional but recommended for fast charts.

```sql
CREATE TABLE daily_nutrition_summaries (
  user_id uuid NOT NULL REFERENCES users(id),
  date date NOT NULL,
  nutrient_id uuid NOT NULL REFERENCES nutrients(id),

  amount numeric NOT NULL,
  unit text NOT NULL,

  updated_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, date, nutrient_id)
);
```

Update this whenever food logs are inserted, updated, or deleted.

Can be recalculated from `food_logs` and `food_log_nutrients` if needed.

---

## Nutrition Calculation Logic

### Product calculation

Input:

```text
product_id
quantity
unit
```

Steps:

1. Convert input quantity to grams.
2. Fetch product nutrients.
3. Calculate each nutrient using:

```text
amount = amount_per_100g * grams / 100
```

---

### Meal calculation

Input:

```text
meal_id
quantity
unit
```

Steps:

1. Fetch meal components.
2. For each component:
   - If product, calculate product nutrients.
   - If meal, recursively calculate meal nutrients.
3. Sum all nutrients.
4. Scale by requested quantity relative to meal total quantity.

---

### Food log calculation

When logging food:

1. Calculate nutrients for selected product or meal.
2. Insert `food_logs` row.
3. Insert calculated nutrient rows into `food_log_nutrients`.
4. Update `daily_nutrition_summaries`.

---

## API Endpoints

### Health

```http
GET /health
GET /version
```

---

### Nutrients

```http
GET /nutrients
GET /nutrients/{code}
```

---

### Food Search / Catalog

```http
GET /foods/search?q=rice
GET /foods/barcode/{barcode}
GET /foods/{id}
GET /foods/{id}/nutrients
GET /foods/{id}/servings
```

Search should include:

```text
name
brand
category
barcode
```

Search ranking preference:

1. Exact barcode match
2. Exact name/brand match
3. Full-text match
4. Trigram fuzzy match

---

### Custom Foods

```http
POST /foods/custom
PUT /foods/custom/{id}
DELETE /foods/custom/{id}
```

Example request:

```json
{
  "name": "My protein shake",
  "serving_size_g": 350,
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount_per_100g": 80 },
    { "code": "PROTEIN_G", "amount_per_100g": 12 },
    { "code": "CARBS_G", "amount_per_100g": 5 },
    { "code": "FAT_G", "amount_per_100g": 2 }
  ]
}
```

---

### Meals / Recipes

```http
POST /meals
GET /meals
GET /meals/{id}
PUT /meals/{id}
DELETE /meals/{id}

POST /meals/{id}/components
PUT /meals/{id}/components/{component_id}
DELETE /meals/{id}/components/{component_id}

GET /meals/{id}/nutrients?quantity=250&unit=g
```

---

### Food Logs

```http
POST /logs
GET /logs?from=2026-05-01&to=2026-05-16
GET /logs/day/2026-05-16
GET /logs/{id}
PUT /logs/{id}
DELETE /logs/{id}
```

Example `POST /logs` request:

```json
{
  "logged_at": "2026-05-16T13:30:00+05:30",
  "meal_slot": "lunch",
  "item_product_id": "...",
  "quantity": 150,
  "unit": "g"
}
```

---

### Summaries / History

```http
GET /summary/day/2026-05-16
GET /summary/range?from=2026-05-01&to=2026-05-16
GET /summary/nutrients?from=2026-05-01&to=2026-05-16&codes=ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G
```

Example response:

```json
{
  "date": "2026-05-16",
  "totals": {
    "ENERGY_KCAL": 2100,
    "PROTEIN_G": 145,
    "CARBS_G": 230,
    "FAT_G": 70
  }
}
```

---

## Bulk Ingestion Interface

Do not let user scripts write directly to the database.

Provide:

1. Bulk file import
2. Bulk HTTP upsert API
3. Import job tracking
4. Error reporting
5. Staging tables before final merge

---

### Import Format

Prefer JSONL for flexibility.

#### `foods.jsonl`

```json
{"source":"OFF","source_id":"123","barcode":"8901234567890","name":"Amul Paneer","brand":"Amul","category":"Dairy","serving_size_g":100}
```

#### `nutrients.jsonl`

```json
{"source":"OFF","source_id":"123","nutrient_code":"ENERGY_KCAL","amount_per_100g":296}
{"source":"OFF","source_id":"123","nutrient_code":"PROTEIN_G","amount_per_100g":18.3}
```

---

### Bulk API

Simple version:

```http
POST /bulk/foods/upsert
POST /bulk/product-nutrients/upsert
```

Job-based version:

```http
POST /imports
POST /imports/{id}/foods
POST /imports/{id}/nutrients
POST /imports/{id}/commit
GET /imports/{id}
GET /imports/{id}/errors
```

Recommended batch size:

```text
500–5000 rows/request
```

---

### `imports`

```sql
CREATE TABLE imports (
  id uuid PRIMARY KEY,
  source text NOT NULL,
  status text NOT NULL, -- pending, running, committed, failed
  created_by uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  committed_at timestamptz
);
```

---

### `import_errors`

```sql
CREATE TABLE import_errors (
  id uuid PRIMARY KEY,
  import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
  row_number bigint,
  error text NOT NULL,
  raw_payload jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

---

### Staging Tables

Use staging tables for import validation and merge.

```sql
CREATE TABLE staging_products (
  import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
  source text NOT NULL,
  source_id text NOT NULL,
  barcode text,
  name text NOT NULL,
  brand text,
  category text,
  serving_size_g numeric,
  raw_payload jsonb,
  row_number bigint
);
```

```sql
CREATE TABLE staging_product_nutrients (
  import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
  source text NOT NULL,
  source_id text NOT NULL,
  nutrient_code text NOT NULL,
  amount_per_100g numeric NOT NULL,
  raw_payload jsonb,
  row_number bigint
);
```

Merge using:

```sql
INSERT INTO products (...)
SELECT ... FROM staging_products
ON CONFLICT (source, source_id)
DO UPDATE SET ...;
```

---

## PWA Frontend Requirements

The frontend should be a Progressive Web App usable from iOS Safari.

Users should be able to open the app in Safari and use:

```text
Share button → Add to Home Screen
```

This avoids initial native iOS distribution, Apple Developer Program, App Store review, and TestFlight complexity.

---

### PWA Features

Required:

```text
Responsive mobile-first UI
Web App Manifest
Service worker
Installable app shell
HTTPS support
Offline fallback page
Local app cache
Food search
Today dashboard
History charts
Meal builder
Custom food editor
Settings/import admin screen
```

Optional later:

```text
Offline logging queue
Background sync where supported
Barcode scanning via web camera APIs
Push notifications
```

Note: iOS PWA capabilities are improving, but background behavior and push/background sync support can be more limited than native apps. Design the app to work well online-first with some local caching.

---

### Frontend Screens

Minimum screens:

```text
Today Dashboard
Food Search
Food Detail
Add Food Log
Log Detail/Edit
History / Charts
Meal List
Meal Builder
Custom Food Editor
Import Jobs / Admin
Settings
```

Primary flow:

```text
Search food → choose quantity → log → see daily totals
```

Meal flow:

```text
Create meal → add products/custom meals → enter quantities → save → log meal
```

Custom food flow:

```text
Create custom food → enter serving size → enter calories/macros → save → log
```

---

## Backend Module Layout

Suggested Rust layout:

```text
src/
  main.rs
  config.rs
  db.rs
  error.rs

  domain/
    user.rs
    food.rs
    nutrient.rs
    meal.rs
    log.rs
    import.rs
    unit.rs

  routes/
    health.rs
    foods.rs
    nutrients.rs
    meals.rs
    logs.rs
    summaries.rs
    imports.rs

  services/
    search_service.rs
    nutrition_calculator.rs
    meal_service.rs
    log_service.rs
    import_service.rs
    summary_service.rs
    unit_conversion_service.rs

  repositories/
    food_repo.rs
    nutrient_repo.rs
    meal_repo.rs
    log_repo.rs
    import_repo.rs
    summary_repo.rs

  jobs/
    import_worker.rs
```

---

## Backend Service Responsibilities

### `search_service`

Responsibilities:

```text
Search products by query
Search by barcode
Rank exact, FTS, trigram matches
Respect user-private visibility
```

---

### `nutrition_calculator`

Responsibilities:

```text
Calculate nutrients for product quantity
Calculate nutrients for meal quantity
Recursively resolve meal components
Prevent infinite recursion
Normalize units
Return macro summary and full nutrient list
```

---

### `meal_service`

Responsibilities:

```text
Create/update/delete meals
Add/update/remove components
Validate component references
Prevent meal cycles
Calculate meal nutrients
```

---

### `log_service`

Responsibilities:

```text
Create food logs
Calculate and snapshot nutrients
Edit food logs
Delete food logs
Update daily summaries
```

---

### `import_service`

Responsibilities:

```text
Create import jobs
Accept batches
Validate rows
Write staging records
Merge staging data into canonical tables
Record import errors
Report import status
```

---

## Historical Data Rule

Food logs must snapshot nutrient values.

Do not rely on live product nutrients for historical summaries.

Reason:

```text
A product's nutrition data may change after import cleanup.
Historical user logs should remain stable.
```

---

## Partitioning and Scaling

Not needed for the MVP.

Possible later partitioning:

```text
food_logs by month
food_log_nutrients by month
product_nutrients by source or hash(product_id)
```

Expected scale for homelab with Open Food Facts and a few national datasets:

```text
products: 1M–7M rows
product_nutrients: 20M–200M rows
food_logs: small unless multi-user
food_log_nutrients: proportional to logs × nutrients snapshotted
```

PostgreSQL is sufficient for this scale on a reasonable homelab machine if indexes are chosen carefully.

---

## Initial MVP Scope

### Phase 1: Core DB and API

Build:

```text
products
nutrients
product_nutrients
product_servings
food_logs
food_log_nutrients
```

Features:

```text
Food search
Product detail
Log product
Daily summary
Custom food with direct nutrients
```

---

### Phase 2: PWA

Build:

```text
Today dashboard
Food search screen
Food detail screen
Add log flow
History screen
Custom food editor
Installable PWA shell
```

---

### Phase 3: Meals

Build:

```text
meals
meal_components
Meal builder UI
Recursive nutrition calculation
Cycle validation
Log meal
```

---

### Phase 4: Bulk Ingestion

Build:

```text
Import jobs
JSONL ingestion
Staging tables
Bulk upsert
Import error reporting
Basic OFF importer script
Basic USDA importer script
```

---

### Phase 5: Improvements

Build:

```text
Daily summary cache
Charts
Macro goals
Better unit conversions
Offline cache
Optional barcode scanning
```

---

## Operational Considerations

### Deployment

For homelab:

```text
Docker Compose or NixOS services
PostgreSQL service
Rust API service
Static PWA served by Caddy or nginx
HTTPS through Caddy, Tailscale certs, or local CA
```

Example service layout:

```text
postgres
api
web
import-worker
```

---

### Backups

Back up PostgreSQL regularly.

Minimum:

```text
nightly pg_dump
weekly full dump retained separately
periodic restore test
```

Catalog data can be reimported, but user logs and custom meals are primary data and must be backed up.

---

### Auth

For homelab MVP:

```text
single-user auth
session cookie
basic login
```

Later:

```text
multi-user accounts
OIDC
Tailscale auth proxy
```

---

## Agent Implementation Instructions

Start with:

1. Create database migrations.
2. Seed canonical nutrients and units.
3. Implement Rust backend health endpoint.
4. Implement product search and product nutrient fetch.
5. Implement custom food creation.
6. Implement food logging with nutrient snapshotting.
7. Implement daily summary query.
8. Build a minimal PWA with Today, Search, Add Log, and History screens.
9. Add meal builder after basic logging works.
10. Add import job system after the core app works.

Do not start with ingestion complexity before the core tracking loop works.

The first working vertical slice should be:

```text
Create/select food → log quantity → snapshot nutrients → show daily calories/macros
```
