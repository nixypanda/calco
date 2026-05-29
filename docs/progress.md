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

### Next steps

- Phase 1.1: `cargo init backend/` with dependencies (axum, sqlx, serde, tokio, argon2, etc.)
- Phase 1.2: Start PostgreSQL via `just up`
- Phase 1.3: Write auth migrations and seed reference data
