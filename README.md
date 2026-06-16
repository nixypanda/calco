# CalCo

CalCo is a self-hosted food and nutrition tracker for a small homelab/household setup.

The app is intentionally simple: search or create foods, log what was eaten, snapshot nutrients at log time, and review the selected day. It also supports reusable meals/recipes and CLI-driven catalog imports from external food datasets.

## Stack

- Backend: Rust, axum, sqlx, PostgreSQL
- Frontend: Elm 0.19.1, elm-ui
- Database: PostgreSQL via Docker Compose
- Tooling: Nix flake, just, Python import scripts

## Current Scope

Implemented:

- Username/password auth with bootstrap admin and admin user management
- Food catalog search/detail, barcode lookup API, custom food CRUD
- Food logs with nutrient snapshots and daily summaries
- Meal/recipe CRUD and meal logging
- Responsive web frontend for daily tracking
- CLI import pipeline for USDA SR Legacy, Open Food Facts India, IFCT 2017, and INDB 2024 data

Not the goal right now:

- Analytics dashboards, trends, or charts
- Browser UI for import jobs
- Offline/service-worker behavior
- Native mobile app

## Command Runner

This is a Nix-based project. Run repository `just` recipes through the dev shell:

```bash
nix develop -c just <recipe>
```

## Quick Start

Start PostgreSQL:

```bash
nix develop -c just up
nix develop -c just db-wait
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-migrate
```

Run the backend:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-dev
```

Run the frontend:

```bash
nix develop -c just frontend-web-dev
```

The backend listens on port `3001` by default. The Elm frontend dev server listens on port `1234`.

## Verification

Reliable current checks:

```bash
nix develop -c just test
nix develop -c just backend-test
nix develop -c just frontend-web-test
nix develop -c just frontend-web-build
```

## Documentation

- [Features](docs/features.md): product checklist and current scope
- [Architecture](docs/architecture.md): system structure and DDD decisions
- [Backend](docs/backend.md): backend domains, APIs, persistence, and invariants
- [Frontend](docs/frontend.md): frontend routes, UI structure, and design rules
- [Imports](docs/imports.md): CLI import pipeline and source merging
- [Operations](docs/operations.md): local operations, env vars, database, tests
- [Known Issues](docs/known_issues.md): accepted risks and cleanup items
