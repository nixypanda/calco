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

### Next steps

- **Phase 6**: Frontend Diary + History (daily diary view, meal-slot grouping, food log CRUD, summary rings, history browsing)
