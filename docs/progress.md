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

### Next steps

- Phase 1.3: Write auth migrations (identities, user_profiles, sessions, auth_audit_events)
- Phase 1.4: Seed reference data (nutrients, units)
- Phase 1.5: Implement auth domain + HTTP routes (bootstrap admin, login, session, user management)
