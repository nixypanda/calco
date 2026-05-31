# Operations

## Local Services

Start PostgreSQL:

```bash
just up
just db-wait
```

Stop PostgreSQL:

```bash
just down
```

Reset PostgreSQL data:

```bash
just db-reset
```

Open psql:

```bash
just db-shell
```

## Backend

Required environment:

```text
DATABASE_URL=postgres://calco:calco@localhost:5432/calco
```

Optional environment:

```text
APP_HOST=0.0.0.0
APP_PORT=3001
SESSION_COOKIE_NAME=calco_session
SESSION_COOKIE_SECURE=false
SESSION_TTL_SECONDS=604800
CORS_ALLOWED_ORIGINS=http://localhost:5173
```

Run:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just backend-dev
```

Build:

```bash
just backend-build
```

Test:

```bash
just backend-test
```

## Frontend

Install:

```bash
cd frontend && pnpm install
```

Run:

```bash
cd frontend && pnpm dev
```

Build:

```bash
cd frontend && pnpm run build
```

Test:

```bash
cd frontend && pnpm test
```

The `justfile` still uses npm for some frontend recipes even though the repo has pnpm lock/workspace files. See [known issues](known_issues.md).

## Test Command Caveat

Use these reliable checks:

```bash
just backend-test
cd frontend
pnpm test
pnpm run build
```

`just test` currently invokes a stale Playwright e2e command. Restore Playwright or remove that recipe before treating `just test` as authoritative.

## Database Migrations

Migrations are embedded and run by the backend on startup:

```text
backend/src/infrastructure/postgres/migrations
```

There is no separate migration binary in the current backend manifest.

## Import Operations

Imports are run from CLI tooling in `tools/importers`.

Typical shape:

```text
convert source data -> optionally merge sources -> import_pipeline.py -> backend import API
```

See [imports.md](imports.md).

## Backup Notes

No dedicated backup tooling exists yet. For homelab use, back up PostgreSQL with normal PostgreSQL tooling such as `pg_dump` or volume snapshots.

Tables worth treating as user-critical:

- `identities`
- `user_profiles`
- `sessions` if preserving login sessions matters
- `products`
- `product_nutrients`
- `product_servings`
- `food_logs`
- `food_log_nutrients`
- `meals`
- `meal_components`
