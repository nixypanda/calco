# Operations

This is a Nix-based project. Run repository `just` recipes through the dev
shell with `nix develop -c just ...`.

## Local Services

Start PostgreSQL:

```bash
nix develop -c just up
nix develop -c just db-wait
```

Stop PostgreSQL:

```bash
nix develop -c just down
```

Reset PostgreSQL data:

```bash
nix develop -c just db-reset
```

Open psql:

```bash
nix develop -c just db-shell
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

Barcode misses require outbound HTTPS access to
`https://world.openfoodfacts.org`. The endpoint is currently fixed in the
backend; no API key or additional environment variable is required. Requests
use a 3-second connection timeout, an 8-second overall timeout, and accept at
most a 1 MiB response. Local barcode hits do not make an OFF request.

Run:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-migrate
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-dev
```

Build:

```bash
nix develop -c just backend-build
```

Test:

```bash
nix develop -c just backend-test
```

See [testing.md](testing.md) for integration tests and coverage.

## Frontend

The active frontend is the Elm app in `frontend-web/`.

Run:

```bash
nix develop -c just frontend-web-dev
```

By default this serves `http://localhost:1234` and proxies `/api/*` to `http://localhost:3001`.

Build:

```bash
nix develop -c just frontend-web-build
```

Test:

```bash
nix develop -c just frontend-web-test
```

Format and review:

```bash
nix develop -c just frontend-web-format
nix develop -c just frontend-web-review
nix develop -c just frontend-web-line-length
```

Use these checks:

```bash
nix develop -c just test
nix develop -c just backend-test
nix develop -c just frontend-web-test
nix develop -c just frontend-web-build
```

## Database Migrations

Migrations live in:

```text
backend/migrations
```

Run migrations separately from app startup:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-migrate
```

The current migration set is a squashed baseline. `nix develop -c just backend-migrate`
uses `sqlx migrate run --ignore-missing` and the baseline SQL is written to
tolerate local databases that already have the previous embedded schema, so
running it records the new baseline without recreating existing tables.

## Import Operations

Imports are run from CLI tooling in two locations:

- **Data sources** (`tools/importers/data-sources/`) — public food datasets via the catalog import API.
- **Personal data** (`tools/importers/personal-data/`) — user data from other apps via user-facing APIs.

Public catalog imports require a running, migrated backend and an admin
`calco_session` token. To upload the existing processed merged catalog JSONL:

```bash
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
nix develop -c just -f tools/justfile data-sources-upload merged data
```

See [imports.md](imports.md) for full workflows, including raw dataset
fetching and merging.

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
