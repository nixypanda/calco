# CalCo Implementation Plan

**Stack:**
- Backend: Rust (axum + sqlx + PostgreSQL)
- Frontend: React + TypeScript + Vite (PWA)
- Infra: Docker Compose (PostgreSQL), just, Nix Flake

---

## Directory Structure

```
CalCo/
├── backend/           # Rust backend (axum + sqlx)
│   └── src/
│       ├── main.rs
│       ├── config.rs
│       ├── domain/        # business logic, no framework deps
│       │   ├── catalog/   # Product, ProductNutrient, ProductServing
│       │   ├── logging/   # FoodLog, FoodLogNutrientSnapshot
│       │   └── nutrition/ # Quantity, Grams, Calculator
│       ├── application/   # use cases + repository ports
│       │   ├── catalog/
│       │   ├── logging/
│       │   ├── summaries/
│       │   └── ports/
│       ├── infrastructure/ # persistence implementations
│       │   └── postgres/
│       │       ├── migrations/
│       │       └── repos/
│       └── interfaces/    # HTTP layer
│           └── http/
│               ├── routes/
│               └── dto/
├── frontend/          # React PWA (Vite + TypeScript)
│   ├── src/
│   │   ├── components/
│   │   ├── pages/
│   │   ├── api/
│   │   ├── hooks/
│   │   └── ...
│   └── ...
├── docs/              # Design docs
├── docker-compose.yml # PostgreSQL service
├── justfile           # Command runner
├── flake.nix          # Nix dev shell + packages (top-level monorepo flake)
└── flake.lock
```

**Nix flake decision:** Top-level single flake that references both `backend/` and `frontend/` as sub-flakes or outputs. Rationale: monorepo, shared dev shell, single `nix develop` to set up all tooling, consistent CI.

---

## Phase 1 — Backend Skeleton + Auth

**Goal:** Rust project bootstrapped, PostgreSQL running via Docker, auth fully working.

### 1.1 — Initialize Rust project

- `cargo init backend/` with name `calco-backend`
- Dependencies: `axum`, `tokio`, `serde`/`serde_json`, `sqlx` (postgres + runtime-tokio), `rust_decimal`, `uuid`, `tower-http`, `tracing`, `argon2`, `rand`, `time`
- Module layout matching DDD structure above
- Config from environment: `DATABASE_URL`, `APP_HOST`, `APP_PORT`, `SESSION_COOKIE_NAME`, `SESSION_COOKIE_SECURE`, `SESSION_TTL_SECONDS`

### 1.2 — Docker Compose

- `docker-compose.yml` at root with `postgres:16` service
- Persisted volume for data
- Exposed on port 5432
- Environment variables for DB name, user, password

### 1.3 — Auth migrations (ref: `auth_design.md:304-349`)

Order:
1. Enable `pg_trgm` extension
2. `identities` — id (uuid PK), username (unique text), password_hash (text), role (text: user/admin), status (text), created_at, updated_at, last_login_at
3. `user_profiles` — id (uuid PK), identity_id (unique FK → identities), display_name (text), created_at, updated_at
4. `sessions` — id (uuid PK), identity_id (FK → identities), session_token_hash (unique text), created_at, last_seen_at, expires_at, revoked_at
5. `auth_audit_events` — id (uuid PK), actor_identity_id (FK → identities), target_identity_id (FK → identities), event_type (text), metadata (jsonb), created_at

Indexes: identities_username_idx, sessions_token_hash_idx, sessions_identity_id_idx, sessions_expires_at_idx

### 1.4 — Auth domain + application + HTTP (ref: `auth_design.md:17-403`)

**Domain:**
- `Identity` entity: id, username, password_hash, role (User|Admin), status (Active|Disabled)
- `UserProfile` entity: id, identity_id, display_name
- `Session` entity: id, identity_id, session_token_hash, expires_at, revoked_at

**Application:**
- `BootstrapAdmin` — create initial admin if none exists
- `Login` — verify credentials, create session, set cookie
- `GetSession` — validate cookie, return identity + profile
- `Logout` — revoke session, clear cookie
- `ChangePassword` — verify current, replace hash, revoke other sessions
- `AdminCreateUser` — create identity + profile
- `AdminResetPassword` — replace hash, revoke all sessions
- `AdminDisableUser` / `AdminEnableUser`

**HTTP routes:**
- `GET  /auth/bootstrap/status` — returns `{ admin_exists: bool }`
- `POST /auth/bootstrap/admin` — create bootstrap admin (fails if already exists)
- `POST /auth/login` — returns identity + profile, sets session cookie
- `GET  /auth/session` — validates cookie, returns current session
- `POST /auth/logout` — revokes session, clears cookie
- `POST /admin/users` — admin creates user
- `GET  /admin/users` — admin lists users
- `POST /admin/users/{id}/reset-password`
- `POST /admin/users/{id}/disable`
- `POST /admin/users/{id}/enable`
- `GET  /me` — current user profile
- `PUT  /me/profile` — update display name
- `POST /me/change-password`
- `GET  /health` / `GET  /version`

**Middleware:** Session cookie extractor → resolves to one of:
- `AuthenticatedIdentity` (any authenticated, including admin)
- `AuthenticatedUser` (rejects admin — admin cannot access food features)
- `AuthenticatedAdmin` (rejects normal users)

### 1.5 — Seed reference data

- `nutrients` table seeded with 11 canonical nutrients (idempotent via code UNIQUE)
- `units` table seeded with 12 canonical units (idempotent via code PK)

---

## Phase 2 — Catalog + Nutrient Domain

**Goal:** Full CRUD for products, product nutrients, product servings, nutrient reference, unit reference.

### 2.1 — Domain layer (ref: `backend_ddd_import_plan.md:42-167`)

**Catalog context:**
- `Product` aggregate root: id, source (Source enum), source_id (optional), user_id (optional), visibility (Global|UserPrivate), barcode, name, brand, category, default_quantity, default_unit, serving_size_g, nutrients (Vec\<ProductNutrient\>), servings (Vec\<ProductServing\>), deleted_at
- `ProductNutrient` value object: nutrient_code, amount_per_100g, source (optional), confidence (optional)
- `ProductServing` value object: label, quantity, unit, grams
- `Nutrient` reference entity: id, code, name, unit, category

**Nutrition context:**
- `Quantity` value object: amount (Decimal), unit (UnitCode)
- `Grams` value object: amount (Decimal)
- `NutrientAmount` value object: nutrient_code, amount, unit
- `CalculatedNutrition` value object: amounts (Vec\<NutrientAmount\>)
- `NutritionCalculator` domain service: `amount = amount_per_100g * grams / 100`
- `UnitConversionPolicy`: MVP rules — g=grams, kg→g, serving/piece/packet/cup/tbsp/tsp require matching ProductServing

### 2.2 — Catalog migrations

- `products` — id (uuid PK), source (text), source_id (text nullable), user_id (uuid FK → user_profiles, nullable), visibility (text), barcode (text nullable), name (text), brand (text nullable), category (text nullable), default_quantity (numeric nullable), default_unit (text nullable), serving_size_g (numeric nullable), deleted_at (timestamptz nullable), created_at, updated_at
  - UNIQUE (source, source_id)
  - Indexes: barcode, source, user_id, brand, category
- `product_nutrients` — product_id + nutrient_id (composite PK), amount_per_100g (numeric), source (text nullable), confidence (text nullable), created_at, updated_at
- `product_servings` — id (uuid PK), product_id (FK → products), label (text), quantity (numeric), unit (text), grams (numeric), created_at
- Search: `search_vector` tsvector GIN index on (name, brand, category, barcode), `name` trigram GIN index, `brand` trigram GIN index

### 2.3 — Application layer — Catalog (ref: `backend_ddd_import_plan.md:432-592`)

Use cases:
- `SearchProducts` — full-text + trigram search, ranking: barcode > exact > FTS > trigram, exclude soft-deleted, include global + user's private
- `GetProductDetail` — load aggregate by id
- `CreateCustomFood` — source=USER, visibility=user_private, atomic insert product + nutrients + servings
- `UpdateCustomFood` — replace nutrients/servings atomically, only user-owned custom foods
- `DeleteCustomFood` — soft delete (set deleted_at), only user-owned custom foods
- `ListNutrients` — all canonical nutrients
- `GetNutrient` — by code
- `ListUnits` — all canonical units

Repository ports: `ProductRepository`, `NutrientRepository`, `TransactionManager`

### 2.4 — Infrastructure — Repository implementations

- `PostgresProductRepository` — SQLx impl with aggregate reconstruction from 3 tables, search with ranking
- `PostgresNutrientRepository` — read-only queries

### 2.5 — HTTP routes — Catalog

- `GET /foods/search?q=` — search results (id, source, source_id, barcode, name, brand, category, serving_size_g)
- `GET /foods/barcode/{barcode}` — single product match
- `GET /foods/{id}` — full detail (all fields + nutrients + servings)
- `POST /foods/custom` — create custom food
- `PUT /foods/custom/{id}` — update custom food
- `DELETE /foods/custom/{id}` — soft delete custom food
- `GET /nutrients` — list canonical nutrients
- `GET /nutrients/{code}` — single nutrient
- `GET /units` — list canonical units

**JSON error shape** (ref: `backend_ddd_import_plan.md:1014-1028`):
```json
{ "error": { "code": "string", "message": "string", "details": {} } }
```

---

## Phase 3 — Logging + Summary Domain

**Goal:** Full food logging with nutrient snapshots, log CRUD, daily/range summaries.

### 3.1 — Domain layer (ref: `backend_ddd_import_plan.md:167-207`)

- `FoodLog` aggregate root: id, user_id, logged_at, meal_slot (optional), item (LoggedItem enum), quantity (Quantity), notes (optional), nutrient_snapshots (Vec\<FoodLogNutrientSnapshot\>)
- `LoggedItem` enum: `Product(ProductId)` [now], `Meal(MealId)` [deferred]
- `FoodLogNutrientSnapshot` value object: nutrient_code, amount (Decimal), unit (UnitCode)
- `MealSlot` value object: constrained to Breakfast|Lunch|Dinner|Snack

### 3.2 — Logging migrations

- `food_logs` — id (uuid PK), user_id (uuid FK → user_profiles), logged_at (timestamptz), meal_slot (text nullable), item_product_id (uuid FK → products, nullable), item_meal_id (uuid FK → meals, nullable), quantity (numeric), unit (text), notes (text nullable), created_at, updated_at
  - CHECK: exactly one item reference set
  - Indexes: (user_id, logged_at), (user_id, meal_slot, logged_at)
- `food_log_nutrients` — food_log_id + nutrient_id (composite PK), amount (numeric), unit (text)
  - FK food_log_id → food_logs ON DELETE CASCADE

### 3.3 — Application layer — Logging (ref: `backend_ddd_import_plan.md:644-838`)

Use cases:
- `LogFood` — load product → convert qty to grams → calculate nutrients → insert log + snapshots (atomic)
- `GetFoodLog` — load aggregate by id
- `GetLogsForRange` — by user, date range, includes snapshots
- `UpdateFoodLog` — recalculate + replace snapshots (atomic)
- `DeleteFoodLog` — delete log (cascade deletes snapshots)
- `GetSummary` — aggregate from food_log_nutrients by date range + nutrient codes (never from live product data)

Repository ports: `FoodLogRepository`, `SummaryRepository`

### 3.4 — HTTP routes — Logging

- `POST /logs` — full request: logged_at, meal_slot, item {type, id}, quantity {amount, unit}, notes → response includes snapped nutrients
- `GET /logs/{id}` — full log with snapshots
- `GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD` — items array with snapshots
- `PUT /logs/{id}` — update fields, recalculate snapshots
- `DELETE /logs/{id}` — remove log
- `GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=ENERGY_KCAL,PROTEIN_G` — totals array

---

## Phase 4 — Frontend: Auth + Login Flow

**Goal:** React PWA initialized, user can bootstrap admin, login, and land on an empty diary.

### 4.1 — Initialize React PWA

- `npm create vite@latest frontend/ -- --template react-ts`
- Dependencies: react-router-dom, tailwindcss (or css modules for utility), zustand or context for state
- PWA: vite-plugin-pwa for manifest + service worker (static cache only, no offline writes)
- System font stack (`-apple-system, BlinkMacSystemFont, "Segoe UI", ...`)
- Mobile-first responsive layout
- Bottom tab navigation on mobile, left sidebar on desktop/tablet

### 4.2 — Auth UI

**Bootstrap admin flow:**
- On first load, `GET /auth/bootstrap/status`
- If `admin_exists: false`, redirect to BootstrapAdminSetup page
- Form: username + password → `POST /auth/bootstrap/admin` → login automatically

**Login flow:**
- Login page: username + password → `POST /auth/login`
- On success, store session (cookie handled by browser), redirect based on role

**Session restore:**
- On app mount, `GET /auth/session` to validate existing cookie
- If valid, route to appropriate home (admin → user management, user → diary)
- If invalid/expired, show login

**Route guards:**
- `UnauthenticatedRoute` → redirects to login if session exists
- `UserRoute` → requires AuthenticatedUser (rejects admin)
- `AdminRoute` → requires AuthenticatedAdmin

### 4.3 — Admin user management page

- User list table (username, display_name, status, created_at)
- Create user form: username, display_name, initial_password
- Reset password, disable, enable actions per user

---

## Phase 5 — Frontend: Catalog UI

**Goal:** User can search foods, view details, create/edit custom foods.

### 5.1 — Food search screen

- Search input with debounce (300ms) → `GET /foods/search?q=`
- Results list: name, brand, category chip, calories per 100g badge
- Empty state: "Search for a food to get started"
- Loading state: skeleton rows
- Tap → navigate to food detail

### 5.2 — Food detail screen

- Header: name, brand, category, barcode (if available)
- Per-100g nutrient table: all snapped nutrients with amounts + units
- Serving options list: label, quantity, grams
- Quantity/serving picker:
  - Text input for amount + unit dropdown (populated from `GET /units`)
  - Quick-select serving buttons from product servings
- "Log" button → `POST /logs` → navigate to diary

### 5.3 — Custom food screens

- Custom food list: same search as global foods (they appear in results)
- Create form:
  - Name (required), brand, category
  - Serving size g, default quantity + unit
  - Nutrient rows: code dropdown + amount_per_100g (add/remove rows)
  - Serving rows: label + quantity + unit + grams (add/remove rows)
- Edit form: pre-populated from `GET /foods/{id}`, same layout as create
- Delete: confirmation dialog → `DELETE /foods/custom/{id}`

---

## Phase 6 — Frontend: Diary + History

**Goal:** Full daily logging flow — see diary, add/edit/delete logs, view summaries, browse history.

### 6.1 — Home / Diary view (ref: `frontend_design.md:102-197`)

**Top summary area:**
- Mobile: calorie ring tile (green) — swipe left to reveal macro ring tile (protein blue / carbs amber / fat rose)
- Desktop: both tiles side-by-side
- Ring is visually filled before goals exist
- Date selector: prev/next arrows + formatted date

**Meal-slot diary:**
- Grouped by Breakfast, Lunch, Dinner, Snack(s)
- Each slot: header (name + calorie total), list of food log rows
- Food log row: food name, quantity text, calorie amount (mobile) + protein/carbs/fat columns (desktop)
- "Add food" button in each slot header → navigates to search
- Tap row → detail/edit view

**Data fetching:**
- `GET /logs?from={date}&to={date}` — all logs for selected day
- `GET /summary?from={date}&to={date}&codes=ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G` — daily totals

### 6.2 — Food log detail/edit

- View mode: food name, quantity, unit, meal slot, logged timestamp, full snapped nutrient list
- Edit mode: editable quantity, unit, meal slot, logged_at, notes
- Save → `PUT /logs/{id}` → refresh diary
- Delete → confirmation → `DELETE /logs/{id}` → refresh diary

### 6.3 — History view

- Date range picker (from, to)
- Summary totals per day in a compact list
- Each row: date, total calories, protein g, carbs g, fat g
- Tap day → navigate to diary for that date
- Data: `GET /summary?from=&to=`

---

## Phase 7 — Meals/Recipes (Next)

**Goal:** Composable meals — create from products, log as single item.

### 7.1 — Backend: Meals domain (ref: `backend_next_later_design.md:16-320`)

- `Meal` aggregate root: id, user_id, name, notes, total_quantity (optional), components (Vec\<MealComponent\>)
- `MealComponent` value object: item (MealComponentItem::Product(ProductId)), quantity
- `MealCyclePolicy` — deferred until nested meals enabled
- `MealNutritionCalculator` — sum component nutrition, scale to requested qty
- Tables: `meals`, `meal_components` (CHECK: exactly one component item reference)

### 7.2 — Backend: Meals API

- `POST /meals` / `GET /meals` / `GET /meals/{id}` / `PUT /meals/{id}` / `DELETE /meals/{id}`
- `GET /meals/{id}/nutrients?quantity=&unit=` — calculate meal nutrition

### 7.3 — Extend logging for meals

- `POST /logs` accepts `item.type: "meal"` in addition to `"product"`
- `FoodLog` domain already supports LoggedItem enum — enable Meal variant

### 7.4 — Frontend: Meals UI

- Meal list screen with search/filter
- Meal builder: name + components (product search + quantity inputs), add/remove component rows, total_quantity
- Meal detail: component list + calculated nutrition table
- Log meal action → navigates to quantity picker → `POST /logs` with meal type

---

## Phase 8 — Import System (Next)

**Goal:** Admin can bulk-import food datasets from JSONL sources.

### 8.1 — Backend: Import domain (ref: `backend_next_later_design.md:321-703`)

- `ImportJob` aggregate root: id, source, status (Pending|Running|Committed|Failed), created_by, timestamps
- `StagedImportProduct` value object: source, source_id, barcode, name, brand, category, serving_size_g, raw_payload, row_number
- `StagedImportNutrient` value object: source, source_id, nutrient_code, amount_per_100g, raw_payload, row_number
- `ImportError` value object: row_number, error, raw_payload
- `ImportValidator` — validate rows against catalog rules
- `ImportCommitPolicy` — status transitions
- Tables: `imports`, `import_errors`, `staging_products`, `staging_product_nutrients`

### 8.2 — Backend: Import API

- `POST /imports` — create job
- `POST /imports/{id}/foods` — stage food rows (500-5000 per request)
- `POST /imports/{id}/nutrients` — stage nutrient rows
- `POST /imports/{id}/commit` — upsert to products/product_nutrients (ON CONFLICT source+source_id)
- `GET /imports/{id}` — job status
- `GET /imports/{id}/errors` — row-level errors
- Admin-only authorization

### 8.3 — Frontend: Import UI (admin)

- Import job list with status badges
- Create import job (select source)
- Upload staging rows (file upload or paste JSONL)
- Commit with confirmation dialog
- Error table with row number, error message, raw payload expand

---

## Phase 9 — Goals + Admin Corrections (Later)

### 9.1 — Backend: Nutrition goals (ref: `backend_next_later_design.md:705-1069`)

- `NutritionGoal` aggregate root: id, user_id, name, period (Daily|Weekly), active_from, active_until, targets (Vec\<GoalTarget\>)
- `GoalTarget` value object: nutrient_code, target (Target enum — Minimum|Maximum|Range|Exact)
- `GoalProgressCalculator` — compare summary against goal targets
- Tables: `nutrition_goals`, `nutrition_goal_targets`
- APIs: `POST/GET/PUT/DELETE /goals`, `GET /goals/active?date=`, `GET /goals/progress?date=`

### 9.2 — Backend: Admin catalog corrections (ref: `backend_next_later_design.md:1071-1121`)

- `PUT /admin/foods/{id}` — same shape as custom food update, but for any product
- Admin-only, audit logged
- Does not mutate historical snapshots

### 9.3 — Frontend: Goals UI

- Goal list with active/inactive status
- Create/edit goal form: name, period, active dates, target rows (nutrient code + target type + values)
- Goal progress on diary home (summary rings become goal-progress indicators)
- Goal progress detail view

### 9.4 — Frontend: Admin correction form

- Global food detail edit (same form as custom food edit)
- Only visible to admin users

---

## Phase 10 — Exports + Reports + Barcode (Later)

### 10.1 — Export jobs (ref: `backend_next_later_design.md:1123-1179`)

- `ExportJob` aggregate: id, user_id, format (JSON|CSV), scope, status, file_path, timestamps, expires_at
- APIs: `POST /exports`, `GET /exports/{id}`, `GET /exports/{id}/download`
- Worker reads through application query interfaces

### 10.2 — Reports (ref: `backend_next_later_design.md:1181-1235`)

- `GET /reports/nutrients/timeseries?from=&to=&interval=day&codes=...`
- `GET /reports/goals/progress?from=&to=`
- Frontend: charts (calories + macros over time, goal progress over time)

### 10.3 — Barcode scanning

- Camera scanner via web camera API
- Manual barcode entry fallback
- `GET /foods/barcode/{barcode}` already exists

---

## Key Architectural Rules

### Enforced from day 1
- `LoggedItem` enum — DB has both `item_product_id` and `item_meal_id` columns with CHECK constraint
- Summary API returns `{code, amount, unit}[]` array — never hardcoded fields
- `Product.source` + `source_id` + `visibility` present even before imports exist
- `NutrientCode` is stable and canonical
- Food log snapshots never recalculated from live product data

### DDD dependency direction
```
interfaces/http → application → domain
infrastructure/postgres → application ports → domain
```

### Auth separation
- `identities` = authentication (login, password, sessions)
- `user_profiles` = application user (food ownership via `user_id`)
- Bootstrap admin has Identity but no UserProfile
- Admin cannot access normal user routes
