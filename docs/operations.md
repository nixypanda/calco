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
CORS_ALLOWED_ORIGINS=http://localhost:1234
```

Run:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just backend-migrate
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

See [testing.md](testing.md) for integration tests, nextest, and coverage.

## Frontend

The active frontend is the Elm app in `frontend-web/`.

Run:

```bash
just frontend-web-dev
```

By default this serves `http://localhost:1234` and proxies `/api/*` to `http://localhost:3001`.

Build:

```bash
just frontend-web-build
```

Test:

```bash
just frontend-web-test
```

Format and review:

```bash
just frontend-web-format
just frontend-web-review
just frontend-web-line-length
```

Use these checks:

```bash
just test
just backend-test
just frontend-web-test
just frontend-web-build
```

## Database Migrations

Migrations live in:

```text
backend/migrations
```

Run migrations separately from app startup:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just backend-migrate
```

The current migration set is a squashed baseline. `just backend-migrate` uses `sqlx migrate run --ignore-missing` and the baseline SQL is written to tolerate local databases that already have the previous embedded schema, so running it records the new baseline without recreating existing tables.

## Import Operations

Imports are run from CLI tooling in two locations:

- **Data sources** (`tools/importers/data-sources/`) — public food datasets via the catalog import API.
- **Personal data** (`tools/importers/personal-data/`) — user data from other apps via user-facing APIs.

See [imports.md](imports.md) for full workflows.

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
