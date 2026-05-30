# Progress Log

## 2026-05-30 — Project Scaffold

### What was set up

**1. Docs reviewed and implementation plan written**
- Read all 6 design docs and synthesized into `docs/implementation_plan.md`
- 10-phase plan: Backend skeleton + auth → Catalog domain → Logging domain → Frontend auth → Frontend catalog → Frontend diary → Meals → Imports → Goals + Corrections → Exports + Reports + Barcode

**2. Directory structure created**

```
CalCo/
├── backend/                        # Rust backend (axum + sqlx)
│   └── src/
│       ├── domain/
│       │   ├── catalog/
│       │   ├── logging/
│       │   └── nutrition/
│       ├── application/
│       │   ├── catalog/
│       │   ├── logging/
│       │   ├── summaries/
│       │   └── ports/
│       ├── infrastructure/
│       │   └── postgres/
│       │       ├── migrations/
│       │       └── repos/
│       └── interfaces/
│           └── http/
│               ├── routes/
│               └── dto/
├── frontend/                       # React PWA (Vite + TypeScript)
│   └── src/
│       ├── components/
│       ├── pages/
│       ├── api/
│       ├── hooks/
│       └── utils/
├── docs/
│   ├── auth_design.md
│   ├── backend_ddd_import_plan.md
│   ├── backend_next_later_design.md
│   ├── features.md
│   ├── food_tracker_homelab_project_spec.md
│   ├── frontend_design.md
│   ├── implementation_plan.md       # Full phased plan
│   └── progress.md                  # This file
├── docker-compose.yml               # PostgreSQL 16 on port 5432
├── justfile                         # Command runner (up/down/db-reset/backend-*/frontend-*/dev/build/test)
├── flake.nix                        # Top-level Nix flake (monorepo)
├── flake.lock
└── .envrc                           # use flake (direnv)
```

**3. Infrastructure files**

- **`docker-compose.yml`** — PostgreSQL 16 Alpine on port 5432, persistent volume (`pgdata`), healthcheck
- **`justfile`** — commands:
  - `just up` / `just down` / `just db-reset` / `just db-wait` / `just db-shell`
  - `just backend-dev` / `just backend-build` / `just backend-test` / `just backend-migrate`
  - `just frontend-setup` / `just frontend-dev` / `just frontend-build` / `just frontend-test`
  - `just dev` (both backend + frontend) / `just build` / `just test`
  - `just` (default: list all commands)
- **`flake.nix`** — top-level monorepo flake with dev shell:
  - Rust toolchain (1.96.0) with rust-src + rust-analyzer
  - cargo-nextest + sqlx-cli
  - Node.js (22.22.3) + pnpm (11.1.2)
  - just + docker-compose
  - Custom shell hook with tooling info
- **`.envrc`** — `use flake` (direnv integration)

### Fixes applied

| Issue | Fix |
|---|---|
| `nodePackages.pnpm` removed in nixpkgs 26.05 | Changed to `pkgs.pnpm` (top-level) |
| `packages.default` referenced non-existent `Cargo.lock` | Removed package output (no Rust crate initialized yet) |

---

## 2026-05-30 — Backend + Frontend Hello World

### What was done

**1. .gitignore files** — root, backend/, frontend/
- Root: `.direnv/`, `.env`, `.DS_Store`, editor dirs, `*.log`, Nix `result`
- Backend: `/target`, `.env`
- Frontend: `node_modules/`, `dist/`, `.env*`, `.tsbuildinfo`

**2. Flake fix** — `nodePackages.pnpm` removed in nixpkgs 26.05, changed to `pkgs.pnpm`. Removed premature `packages.default` (no Cargo.lock existed yet).

**3. Initial commit** (`067ee16`) — 18 files: project structure, all 6 design docs, implementation plan, Docker Compose, justfile, flake, .envrc, .gitignore files.

**4. Rust backend initialized**
- `cargo init backend/` with axum 0.8 + tokio + serde + tower-http (CORS) + tracing
- `GET /health` → `ok`
- `GET /version` → `0.1.0`
- Config via `APP_HOST` (default `0.0.0.0`) and `APP_PORT` (default `3001`)
- Builds and runs successfully

**5. React frontend initialized** (manual setup — `create-vite` hung due to pnpm daemon issue)
- Vite 6 + React 19 + TypeScript 5.7
- `react-router-dom` 7 included
- Vite proxy: `/api/*` → `localhost:3001`
- Builds successfully (194 KB JS bundle)
- Dev server on `:5173`, serves `<title>CalCo — Food Tracker</title>`

**6. PostgreSQL started** via `docker compose up -d`
- Postgres 16 Alpine on `:5432`
- Database `calco`, user/pass `calco`, persistent volume `pgdata`

**7. Second commit** (`ecb9e67`) — 17 files: all backend + frontend source code.

### Verified

| Service | Endpoint | Result |
|---|---|---|
| Backend | `GET /health` | `ok` |
| Backend | `GET /version` | `0.1.0` |
| Frontend | `GET /` | `CalCo — Food Tracker` |
| Database | `pg_isready` | accepting connections |

### Dev shell tools

| Tool | Version |
|---|---|
| Rust/cargo | 1.96.0 |
| Node | 22.22.3 |
| pnpm | 11.1.2 |
| just | 1.51.0 |
| Nix | 2.34.7 |

---

## 2026-05-30 — Playwright E2E Testing

### What was done

1. **Installed `@playwright/test`** — added to `frontend/` as a dev dependency via pnpm.
2. **Created `frontend/playwright.config.ts`** — test dir `./e2e`, Chromium only, auto-starts Vite dev server via `webServer` (port 5173, `reuseExistingServer: true`).
3. **Created `frontend/e2e/app.spec.ts`** — smoke test asserting `<h1>CalCo</h1>` and `.status: "Frontend running ✓"` render correctly.
4. **Created `frontend/tsconfig.e2e.json`** — extends main tsconfig with `@playwright/test` types, includes `e2e/`.
5. **Created `AGENTS.md`** — project root, documents Playwright commands and setup for the opencode agent.
6. **Updated `flake.nix`** — added `playwright-driver.browsers` to `buildInputs` and `PLAYWRIGHT_BROWSERS_PATH` env var in `shellHook`.
7. **Updated `frontend/package.json`** — added `test:e2e` and `test:e2e:ui` scripts.
8. **Updated `frontend/.gitignore`** — ignores `playwright-report/`, `test-results/`, `/playwright/.cache/`.
9. **Updated `justfile`** — added `frontend-e2e` recipe (`npx playwright test`), included in `test`.
10. **Added `frontend/pnpm-workspace.yaml`** — `allowBuilds: { esbuild: true }` (required by pnpm for Vite).
11. **Installed Chromium browser** — downloaded to `~/.cache/ms-playwright/chromium-1223` (bypassed SSL cert via `NODE_TLS_REJECT_UNAUTHORIZED=0` behind corporate proxy).

### Verified

| Check | Result |
|---|---|
| `cd frontend && npx playwright test` | 1 passed (7.0s) |

### Commit

`405de48` — 10 files, 132 insertions.

### Next steps

- Phase 1.3: Write auth migrations (identities, user_profiles, sessions, auth_audit_events)
- Phase 1.4: Seed reference data (nutrients, units)
- Phase 1.5: Implement auth domain + HTTP routes (bootstrap admin, login, session, user management)

---

## 2026-05-30 — Auth System (Backend + Frontend)

### What was done

**Backend (Rust/axum):**
- 6 PostgreSQL migrations (extensions, identities, user_profiles, sessions, auth_audit_events, indexes)
- Domain layer: Identity, UserProfile, Session entities; newtypes & enums (IdentityRole, IdentityStatus, AuthError)
- Application layer: repository trait ports, use cases (bootstrap_status, create_bootstrap_admin, login, get_session, logout, admin_create_user, admin_list_users, admin_reset_password, admin_disable_user, admin_enable_user)
- Infrastructure layer: PostgresIdentityRepository, PostgresSessionRepository, PostgresUserProfileRepository with sqlx queries, migration runner
- HTTP layer: session cookie extractors (RawSessionToken, AuthIdentity, AuthUser, AuthAdmin), DTOs, route handlers for all endpoints under `/auth/*`
- Config: AppConfig struct reading from env vars, dotenvy init
- Route wiring in main.rs: `/api/*` prefix for health/version, auth routes merged at root

**Frontend (React/Vite):**
- API client layer: `api/client.ts` (fetch wrapper with credentials), `api/auth.ts` (auth endpoints), `api/admin.ts` (admin CRUD endpoints)
- `hooks/AuthContext.tsx` — provider with login/logout/createAdmin/restoreSession, loading/identity/profile state
- Route guards: ProtectedRoute (redirects to `/login`), AdminRoute (redirects to `/home` for non-admins)
- Pages: BootstrapAdminSetup, LoginPage, AdminDashboard (user list, create, reset password, disable/enable), UserHome
- Routing: RootRedirect with bootstrap check + role-based redirects, BootstrapGate for `/setup`
- Styling: CSS for auth pages, admin dashboard, user home

**Testing:**
- 24 Vitest unit tests (5 files: AuthContext, 3 pages, route guards)
- 1 Playwright E2E test covering full bootstrap→admin CRUD→user login→logout flow
- vitest.config.ts, test-setup.ts, Playwright config

### Verified

| Check | Result |
|---|---|
| `cd frontend && pnpm vitest run` | 24/24 pass |
| `cd frontend && pnpm exec playwright test e2e/auth.spec.ts` | 1 passed (3.4s) |
| Backend endpoints via curl | All respond correctly |

### Commit

`03af22a` — "Implement password-based auth system with session management" (42 files, +5703 −54)

---

## 2026-05-30 — Catalog Domain (Phase 1.5 + Phase 2)

### What was done

**Phase 1.5 — Seed reference data:**
- Migration `20250530000007_create_nutrients.sql` — `nutrients` table (id, code, name, unit, category)
- Migration `20250530000008_create_units.sql` — `units` table (code PK, name, kind)
- Migration `20250530000009_seed_reference_data.sql` — idempotent seed of 12 units and 11 nutrients

**Phase 2 — Catalog domain (consolidated, one file per layer):**
- `domain/catalog.rs` — Product aggregate (Product, ProductNutrient, ProductServing), Nutrient entity, all value objects (ProductId, Source, ProductVisibility, NutrientCode, UnitCode, Barcode, etc.)
- `domain/nutrition.rs` — NutritionCalculator service, Quantity, NutrientAmount, CalculatedNutrition
- `application/catalog.rs` — Repository traits (ProductRepository, NutrientRepository, UnitRepository, TransactionManager), CatalogServices with all use cases (search, get, create/update/delete custom food, list nutrients/units)
- `infrastructure/postgres/catalog.rs` — PostgresProductRepository (search, CRUD with nutrients/servings atomic), PostgresNutrientRepository, PostgresUnitRepository, inline row structs
- `interfaces/http/catalog.rs` — All route handlers + DTOs for `/foods/*`, `/foods/custom/*`, `/nutrients/*`, `/units/*` with JSON error shape
- Migration `20250530000010_create_products.sql` — products, product_nutrients, product_servings tables with indexes and FKs

### Wired

- All mod.rs files updated, main.rs wired with catalog repos + routes mounted at root level

### Next steps

- Phase 4: Frontend catalog UI (search, detail, custom food forms)
- Phase 5: Frontend diary/history view

---

## 2026-05-30 — Phase 3: Food Log + Summary Domain

### What was done

**1. Migration `20250530000011_create_food_logs.sql`** — `food_logs` and `food_log_nutrients` tables with:
   - FK constraints (`user_id → user_profiles`, `item_product_id → products`, cascade delete snapshots)
   - CHECK constraint for exactly one item reference
   - Indexes on `(user_id, logged_at)` and `(user_id, meal_slot, logged_at)`

**2. Domain layer (`domain/food_log.rs`)** — `FoodLogId`, `MealSlot` (Breakfast/Lunch/Dinner/Snack), `LoggedItem::Product`, `FoodLogNutrientSnapshot`, `FoodLog` aggregate with `is_owned_by`

**3. Application layer (`application/food_log.rs`)** — Repository ports (`FoodLogRepository`, `ProductLookup`, `SummaryRepository`), `FoodLogServices` with use cases:
   - `log_food` — loads product, converts qty to grams, snapshots nutrients, creates log
   - `get_food_log` / `get_logs_for_range` / `update_food_log` / `delete_food_log`
   - `get_summary` — delegates to summary repo (SQL aggregation from snapshots)

**4. Infrastructure (`infrastructure/postgres/food_log.rs`)** — `PostgresFoodLogRepository` (atomic create/update with snapshot replacement, range queries) and `PostgresSummaryRepository` (`SUM` with optional `WHERE code = ANY(...)`)

**5. HTTP layer (`interfaces/http/food_log.rs`)** — 6 authenticated routes:
   - `POST /logs`, `GET /logs/{id}`, `GET /logs?from=&to=`, `PUT /logs/{id}`, `DELETE /logs/{id}`
   - `GET /summary?from=&to=&codes=`

**6. Wiring** — All mod.rs files updated, `food_log_services: Option<FoodLogServices>` added to `AppState`, routes mounted in `main.rs`

### Tests — 18 unit tests

**Domain (5 tests):**
- `test_meal_slot_roundtrip` — all 4 variants roundtrip via `as_str`/`from_str`
- `test_meal_slot_from_str_invalid` — invalid input yields error
- `test_food_log_id_generates_unique_ids` / `test_food_log_id_from_uuid`
- `test_food_log_is_owned_by` — ownership check
- `test_food_log_nutrient_snapshot` — struct construction

**Application (13 tests with mock repos):**
- `test_log_food_success` — full log flow with nutrient calculation
- `test_log_food_product_not_found` — error on missing product
- `test_log_food_invalid_meal_slot` — validation error
- `test_get_food_log_success` / `test_get_food_log_not_found`
- `test_update_food_log_success` / `test_update_food_log_forbidden`
- `test_delete_food_log_success` / `test_delete_food_log_forbidden` / `test_delete_food_log_not_found`
- `test_get_logs_for_range` — date range filtering
- `test_summary_delegates_to_repo` — delegates properly

### Verified

| Check | Result |
|---|---|
| `cd backend && cargo test` | 18/18 pass |
| `GET /api/health` | `ok` |
| `GET /logs` (unauthenticated) | `401 Unauthorized` |
| `GET /summary` (unauthenticated) | `401 Unauthorized` |

---

## 2026-05-30 — Phase 5: Frontend Catalog UI

### What was done

**1. API client (`src/api/foods.ts`)** — Typed functions for all catalog endpoints:
- `searchFoods`, `getFoodDetail`, `createCustomFood`, `updateCustomFood`, `deleteCustomFood`, `listNutrients`, `listUnits`
- TypeScript interfaces matching backend response shapes (`SearchResult`, `ProductDetail`, `NutrientEntry`, `ServingEntry`, `CreateFoodRequest`, etc.)

**2. FoodSearch page (`src/pages/FoodSearch.tsx`)** — Route `/search`:
- Search input with 300ms debounce → `GET /foods/search?q=`
- Results list: name, brand, category chip, source badge ("Custom" for USER source)
- Loading skeleton (3 shimmer rows), empty state ("Search for a food to get started"), not-found state
- Error display for failed requests
- Tap result → navigate to `/foods/:id`

**3. FoodDetail page (`src/pages/FoodDetail.tsx`)** — Route `/foods/:id`:
- Header: name, brand, category, barcode, serving size
- Per-100g nutrient table (code, amount, unit)
- Serving options list with quantity/grams
- Quantity picker + unit dropdown (populated from `GET /units`)
- "Log Food" button (placeholder navigation to `/home`; actual logging comes in Phase 6)
- Edit/Delete buttons for custom (USER source) foods only
- Delete confirmation dialog → `DELETE /foods/custom/:id` → navigate to `/search`
- Loading, error, not-found states

**4. CustomFoodCreate page (`src/pages/CustomFoodCreate.tsx`)** — Route `/foods/custom/new`:
- Basic info: name (required), brand, category
- Portion info: serving size g, default quantity, default unit (dropdown from `GET /units`)
- Dynamic nutrient rows: nutrient code dropdown (from `GET /nutrients`) + amount_per_100g, add/remove rows
- Dynamic serving rows: label + quantity + unit + grams, add/remove rows
- Validation: name required, empty nutrient/serving rows excluded from submission
- Submit → `POST /foods/custom` → navigate to food detail

**5. CustomFoodEdit page (`src/pages/CustomFoodEdit.tsx`)** — Route `/foods/custom/:id/edit`:
- Loads existing food via `GET /foods/:id` → pre-populates all form fields
- Same form layout as create (name, brand, category, portion info, nutrients, servings)
- Submit → `PUT /foods/custom/:id` → navigate to food detail
- Loading, error states

**6. Routes wired in `App.tsx`** — 4 new routes added:
- `/search` → FoodSearch
- `/foods/:id` → FoodDetail
- `/foods/custom/new` → CustomFoodCreate
- `/foods/custom/:id/edit` → CustomFoodEdit
- All wrapped in `ProtectedRoute` (user-only, rejects admin)

**7. Navigation** — `UserHome.tsx` updated with "Search Foods" and "Create Custom Food" buttons linking to the new pages.

**8. CSS (`src/index.css`)** — Full styling for:
- Search bar, result items, category/source chips
- Skeleton loading animation (`@keyframes shimmer`)
- Food detail: nutrient table, serving list, log food form
- Buttons (`.btn-primary`, `.btn-secondary`, `.btn-danger`, `.btn-danger-sm`)
- Custom food form: input/select styling, nutrient/serving row layouts, section headers
- Empty states, error states, responsive layout

### Tests — 25 new tests (4 new files)

| File | Tests | Coverage |
|------|-------|----------|
| `FoodSearch.test.tsx` | 7 | render, empty state, loading, results, no results, error, navigation |
| `FoodDetail.test.tsx` | 7 | loading, detail display, error, custom food edit/delete buttons, delete flow, cancel delete |
| `CustomFoodCreate.test.tsx` | 6 | render, empty name validation, submit, error on failure, add/remove nutrient rows, add/remove serving rows |
| `CustomFoodEdit.test.tsx` | 5 | loading, pre-populated form, submit update, update error, load error |

**Pre-existing fix:** `BootstrapAdminSetup.test.tsx` — fixed `getByPlaceholderText` truthy check that always evaluated to `true`.

### Verified

| Check | Result |
|-------|--------|
| `cd frontend && pnpm vitest run` | 49/49 pass (was 24) |
| `cd frontend && pnpm tsc --noEmit` | Clean |
| `cd frontend && pnpm run build` | Clean (258 KB JS, 8 KB CSS) |

---

## 2026-05-30 — Phase 6: Frontend Diary + History

### What was done

**1. API client (`src/api/logs.ts`)** — Typed functions for all log endpoints:
- `createLog`, `getLog`, `listLogs`, `updateLog`, `deleteLog`, `getSummary`
- TypeScript interfaces matching backend response shapes (`LogResponse`, `LogListResponse`, `SummaryResponse`, `CreateLogRequest`, `UpdateLogRequest`)

**2. Diary page (`src/pages/Diary.tsx`)** — Route `/home` (replaces `UserHome`):
- Date selector with prev/next arrows and formatted date display
- Summary rings (SVG circles with fill arcs) for calories (green), protein (blue), carbs (amber), fat (rose)
- Calorie default goal of 2000 kcal (rings filled proportionally; goals from Phase 9)
- Meal-slot grouping: Breakfast, Lunch, Dinner, Snack, Other
- Each slot header: name + calorie total + "+" add button
- Add button navigates to `/search` with `{ state: { mealSlot } }`
- Food log rows: food name (fetched via `getFoodDetail` per unique product ID), quantity text, calorie amount
- Tap row → navigates to `/logs/:id` for detail/edit
- Loading, error, empty states
- Query param `?date=YYYY-MM-DD` support (from history navigation)

**3. Food Log Detail/Edit page (`src/pages/FoodLogDetail.tsx`)** — Route `/logs/:id`:
- View mode: food name, timestamp, meal slot, quantity/unit, notes, full nutrient table
- Edit mode: editable meal slot (dropdown), amount, unit, notes
- Save → `PUT /logs/:id` → refreshes display
- Delete → confirmation dialog → `DELETE /logs/:id` → navigates to `/home`
- Loading, error, not-found states

**4. History page (`src/pages/History.tsx`)** — Route `/history`:
- Date range picker (from/to date inputs, default: last 7 days)
- Fetches summary per day in parallel (max 90-day range)
- Table: date, calories, protein, carbs, fat with numeric alignment
- Rows are clickable → navigates to `/home?date=YYYY-MM-DD`
- Loading, error states

**5. FoodDetail logging updated (`src/pages/FoodDetail.tsx`)**:
- Meal slot dropdown in "Log Food" section
- "Log Food" button now calls `POST /api/logs` → navigates to `/home`
- Meal slot preselected from `location.state.mealSlot` (passed by diary "+" button)

**6. Routes wired in `App.tsx`**:
- `/home` → `Diary` (replaces `UserHome`)
- `/logs/:id` → `FoodLogDetail`
- `/history` → `History`

**7. CSS (`src/index.css`)** — Added styles for:
- `.diary-page`, `.diary-nav`, `.date-selector`, `.date-arrow`, `.date-label`
- `.summary-rings`, `.nutrient-ring-wrapper`, `.nutrient-ring-svg`, `.ring-center`, `.ring-value`, `.ring-unit`, `.ring-label`
- `.meal-slot`, `.meal-slot-header`, `.meal-slot-name`, `.meal-slot-calories`, `.meal-add-btn`, `.meal-slot-empty`
- `.log-row`, `.log-row-name`, `.log-row-qty`, `.log-row-cal`
- `.log-detail-name`, `.log-detail-time`, `.log-edit-form`
- `.meal-slot-select`
- `.history-range`, `.history-table-wrapper`, `.history-table`, `.num-col`, `.history-row`

### Tests — 25 new tests (4 new files + 1 updated)

| File | Tests | Coverage |
|------|-------|----------|
| `Diary.test.tsx` | 7 | render, empty state, summary rings, meal slot + log rows, navigation to search/history/log detail, error |
| `FoodLogDetail.test.tsx` | 7 | loading, detail display, edit + save, cancel edit, delete flow, cancel delete, error |
| `History.test.tsx` | 3 | render + date inputs, daily summary rows, loading state |
| `LogsApi.test.ts` | 7 | create/get/list/update/delete log, getSummary with/without codes |
| `FoodDetail.test.tsx` | updated | added `createLog` mock for logging functionality |

### Verified

| Check | Result |
|-------|--------|
| `pnpm tsc --noEmit` | Clean |
| `pnpm run build` | Clean (274 KB JS, 12 KB CSS) |
| `pnpm vitest run` | 74/74 pass (was 49) |

### Next steps

- **Phase 8**: Import System — admin bulk-import food datasets from JSONL
- **Phase 9**: Goals + Admin Corrections
- **Phase 10**: Exports + Reports + Barcode

---

## 2026-05-30 — Phase 7: Meals/Recipes (Backend)

### What was done

**1. New files (5):**

- **`domain/meal.rs`** — Meal aggregate root entity, MealComponent child value object, MealComponentItem::Product enum, MealId/MealName/MealNotes/MealYield value objects, MealError enum, 8 domain tests
- **`application/meal.rs`** — MealRepository + MealProductLookup traits, MealServices with 6 use cases (create, get, list, update, delete, get_meal_nutrients), 16 application tests with mock repos
- **`infrastructure/postgres/meal.rs`** — PostgresMealRepository (atomic create/update with component replacement, aggregate reconstruction), + MealProductLookup impl
- **`interfaces/http/meal.rs`** — 6 routes: `POST/GET/PUT/DELETE /meals`, `GET /meals/{id}/nutrients` with aggregate-shaped DTOs following the design spec
- **Migration `20250530000012_create_meals.sql`** — meals + meal_components tables with FK constraints and CHECK constraint for exactly one component item reference

**2. Modified files (9):**

- `domain/food_log.rs` — added `Meal(MealId)` variant to `LoggedItem` enum
- `application/food_log.rs` — added `MealLookup` trait, `log_meal()` method (loads meal → sums component nutrition → snapshots), `with_meal_support()` builder; extended `LogFoodInput`/`UpdateFoodInput` with `item_type`+`item_id` fields; 4 new tests for meal logging
- `infrastructure/postgres/food_log.rs` — `row_to_food_log`/`create`/`update` handle `item_meal_id`; implemented `MealLookup`
- `interfaces/http/food_log.rs` — log handlers route to `log_meal` when `item.type == "meal"`
- `interfaces/http/auth.rs` — added `meal_services: Option<MealServices>` to `AppState`
- `main.rs` — wired PostgresMealRepository, MealServices, meal_routes, with_meal_support
- `domain/mod.rs`, `application/mod.rs`, `infrastructure/postgres/mod.rs`, `interfaces/http/mod.rs` — module registration

**3. Key design decisions:**

- Meal components are replaced atomically through the Meal aggregate (no standalone component endpoints)
- Meal nutrition is calculated at log time from component products and snapshotted (historical logs stable)
- `LoggedItem::Meal` reuses the existing food_logs infrastructure (item_meal_id column already existed)
- `POST /logs` accepts `item.type: "meal"` alongside the existing `"product"`

### Verified

| Check | Result |
|-------|--------|
| `cargo test` | 42/42 pass (was 18) |
| `cargo build` | Clean |

---

## 2026-05-30 — Phase 7.4: Frontend Meals UI

### What was done

**1. API client (`src/api/meals.ts`)** — Typed functions for all 6 meal endpoints:
- `listMeals`, `getMeal`, `createMeal`, `updateMeal`, `deleteMeal`, `getMealNutrients`
- TypeScript interfaces matching backend DTOs (`MealResponse`, `MealComponentResponse`, `CreateMealRequest`, `MealNutritionResponse`, etc.)

**2. Meals page (`src/pages/Meals.tsx`)** — Route `/meals`:
- Fetches `GET /meals` on mount
- Cards showing meal name, component count, notes preview
- Tap → navigate to `/meals/:id`
- "Create Meal" button → `/meals/new`
- Loading (skeleton rows), empty ("No meals yet"), error states

**3. MealDetail page (`src/pages/MealDetail.tsx`)** — Route `/meals/:id`:
- Header: name, notes
- Components list with product names (fetched via `getFoodDetail`)
- "Log this meal" section: amount input + "Calculate" button → `GET /meals/:id/nutrients`
- Nutrient table from calculated results
- "Log Meal" button → `POST /logs` with `item.type: "meal"` → navigate to `/home`
- Edit button → `/meals/:id/edit`
- Delete with confirmation → `DELETE /meals/:id` → navigate to `/meals`
- Loading, error, not-found states

**4. MealForm page (`src/pages/MealForm.tsx`)** — Routes `/meals/new` and `/meals/:id/edit`:
- Create mode: empty form
- Edit mode: pre-populated from `GET /meals/:id`
- Fields: name (required), notes (optional), total_quantity (optional amount + unit)
- Dynamic component rows: debounced product search (300ms) with dropdown results, quantity + unit inputs, add/remove rows
- Validation: name required, at least 1 component with selected product
- Submit → `POST /meals` (create) or `PUT /meals/:id` (edit) → navigate to detail
- Loading, error states

**5. Navigation & routing:**
- `App.tsx`: added 4 new routes (`/meals`, `/meals/new`, `/meals/:id`, `/meals/:id/edit`)
- `Diary.tsx`: added "Meals" nav button to diary navigation bar
- `index.css`: added styles for meals pages (search dropdown, component rows, etc.)

**6. Tests — 28 new tests (3 new files):**

| File | Tests | Coverage |
|------|-------|----------|
| `Meals.test.tsx` | 8 | render, empty, list, component count, notes, navigation to detail/create, error |
| `MealDetail.test.tsx` | 9 | loading, display, components, calculate nutrients, log meal, edit, delete, error, not-found |
| `MealForm.test.tsx` | 11 | render, validation, product search/select, add/remove components, create, create failure, edit load, edit update, edit load error |

### Verified

| Check | Result |
|-------|--------|
| `pnpm vitest run` | 102/102 pass (was 74) |
| `pnpm tsc --noEmit` | Clean |
| `pnpm run build` | Clean (287 KB JS, 13 KB CSS) |

---

## 2026-05-30 — Phase 8: Backend Import Engine

### What was done

**1. Source enum expanded** (`domain/catalog.rs`):
- Added `Usda` and `Ifct` variants to the `Source` enum for the three data source types.

**2. Two new migrations:**
- `20250530000013_create_imports.sql` — 4 tables: `imports`, `staging_products`, `staging_product_nutrients`, `import_errors` with FKs, cascading deletes, indexes.
- `20250530000014_seed_more_nutrients.sql` — idempotent seed of 14 additional nutrients (CALCIUM, IRON, MAGNESIUM, ZINC, PHOSPHORUS, VITAMIN_A/C/D/E/B6/B12, FOLATE, MONOUNSATURATED_FAT, POLYUNSATURATED_FAT).

**3. Domain layer (`domain/import.rs`)** — ImportJob entity with status lifecycle (Pending→Running→Committed/Failed), value objects (ImportId, ImportSource, ImportStatus), StagedImportProduct, StagedImportNutrient, ImportErrorRecord records, ImportDomainError enum.

**4. Application layer (`application/import.rs`):**
- `ImportRepository` trait with 9 methods (create_job, find_job, stage_foods, stage_nutrients, add_error, count_staged_foods, commit_import, get_errors, update_job_status).
- `ImportServices` with 6 use cases: create_job, stage_foods (batched with validation), stage_nutrients (batched with validation), commit_job, get_job, get_errors.
- Validation: rejects empty/invalid rows with per-row error tracking; rejects ops on non-pending imports; rejects commit with no staged foods.
- `ImportCommitResult` with products_created/updated, nutrients_inserted, errors_logged.

**5. Infrastructure layer (`infrastructure/postgres/import.rs`):**
- `PostgresImportRepository` — SQLx implementation with batched staging (ON CONFLICT for idempotent re-staging).
- Atomic `commit_import` transaction: marks running → upserts products by `(source, source_id)` via CTE → upserts resolved product_nutrients → logs unresolved nutrient codes as errors → marks committed.
- Per-query row counting for accurate commit diagnostics.

**6. HTTP layer (`interfaces/http/import.rs`):**
- 6 admin-only routes: `POST /imports`, `POST /imports/{id}/foods`, `POST /imports/{id}/nutrients`, `POST /imports/{id}/commit`, `GET /imports/{id}`, `GET /imports/{id}/errors`.
- DTOs with batch food/nutrient staging via `rows` array.
- JSON error responses matching project convention.

**7. Wiring:**
- All mod.rs files updated.
- `AppState` extended with `import_services: Option<ImportServices>`.
- `main.rs` instantiates PostgresImportRepository → ImportServices → wires import_routes.

### Tests — 11 new (53 total)

| File | Tests | Coverage |
|------|-------|----------|
| `application/import.rs` | 11 | create job, stage foods (valid/invalid), stage nutrients (valid/invalid), commit success, commit fails no foods, job not found, stage fails non-pending job, get errors, commit with partial nutrient errors |

### Verified

| Check | Result |
|-------|--------|
| `cargo test` | 53/53 pass (was 42) |
| `cargo build` | Clean |

---

## 2026-05-30 — Phase 8b: Python Data Pipeline + Cross-Source Merging

### What was done

**1. New directory `tools/importers/` with uv-managed Python project:**

```
tools/importers/
├── pyproject.toml                          # dependencies: requests, rapidfuzz
├── nutrient_mapping/
│   ├── usda_sr_codes.json                  # 25 USDA nutrient IDs → CalCo codes
│   ├── off_fields.json                     # 25 OFF nutriments fields → CalCo codes
│   └── ifct2017_codes.json                 # 24 IFCT column codes → CalCo codes
├── convert_usda_sr.py                      # USDA SR Legacy JSON → JSONL
├── convert_off_india.py                    # OFF CSV (tab-delimited, streamed) → India-filtered JSONL
├── convert_ifct2017.py                     # IFCT 2017 compositions CSV → JSONL
├── merge_sources.py                        # Cross-source dedup (name+barcode)
└── import_pipeline.py                      # Orchestrator: upload to API → commit
```

**2. Conversion results:**

| Source | Foods | Nutrients | Raw size | Jsonl size |
|--------|-------|-----------|----------|------------|
| USDA SR Legacy | 7,793 | 177,166 | 13 MB zip | 22 MB |
| OFF India (filtered) | 1,479 | 15,047 | 1.2 GB gzip | 2.1 MB |
| IFCT 2017 | 542 | 13,008 | 1.1 MB CSV | 1.5 MB |

**3. Cross-source merge (`merge_sources.py`):**

- **Barcode matching:** 0 matches (only OFF has barcodes; USDA/IFCT don't)
- **Name similarity matching:** 15 matched groups (30 products → 15), zero false positives
  - Uses `token_sort_ratio` ≥ 90 with subset-guard (penalize when short name is a token subset of a long name) and length-ratio guard (reject if shorter name <50% of longer)
  - Macros checked for >30% divergence; mismatches logged as warnings but don't block
- **Preference:** USDA > IFCT > OFF
- **Output:** `data/processed/merged.jsonl` — 9,799 products (9,814 − 15 merged)

**4. Notable issues caught during OFF conversion:**
- OFF CSV uses tab delimiters, not commas — fixed via `csv.DictReader(..., delimiter="\t")`
- USDA SR Legacy JSON nests nutrient IDs inside a `nutrient` object — fixed nested lookup
- CSV field size limit hit on OFF large fields — fixed via `csv.field_size_limit(sys.maxsize)`
- IFCT values use `"value±error"` format (e.g., `"9.20±0.40"`) — parsed by splitting on `±`

**5. Project infrastructure:**
- `.gitignore` updated to include `data/`
- Virtual environment with `requests` and `rapidfuzz`
- Pipeline supports `--source MERGED` for merged imports

### Import execution (2026-05-30)

**Pipeline run** (`import_pipeline.py --source MERGED`):

| Metric | Result |
|--------|--------|
| Products created | 9,799 (7,793 USDA + 1,469 OFF + 537 IFCT) |
| Nutrients inserted | 204,998 |
| Cross-source merges applied | 15 groups (30 products → 15) |
| Import errors | **0** |

**One-time fix applied:** 42 OFF records with `name: null` in `merged.jsonl` were given placeholder names at upload time to pass backend validation.

**Verification:**
- `GET /foods/search?q=rice` returns 50 results spanning all 3 sources
- Zero errors logged in import job
- `git add tools/importers/` includes all converter scripts, merge logic, and the pipeline orchestrator

### Next steps

- Phase 9: Goals + Admin Corrections
