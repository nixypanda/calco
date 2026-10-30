# Local Development

This is a Nix-based project. Enter the development shell once and run repository
`just` recipes inside it:

```bash
nix develop
just <recipe>
```

For production/host setup, see [deployment.md](deployment.md).

For a first run, start PostgreSQL under [Local Services](#local-services),
apply migrations and start the backend under [Backend](#backend), then start
the frontend under [Frontend](#frontend).

## Local Services

Start PostgreSQL:

```bash
just db-up
just db-wait
```

Stop PostgreSQL:

```bash
just db-down
```

Reset PostgreSQL data:

```bash
just db-reset
```

Open psql:

```bash
just db-shell
```

## Environment

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

The backend parses these variables through `load_env` into `EnvSourceConfig`
(`backend/src/config/source/env.rs`).

Barcode misses require outbound HTTPS access to
`https://world.openfoodfacts.org`. The endpoint is currently fixed in the
backend; no API key or additional environment variable is required. Requests
use a 3-second connection timeout, an 8-second overall timeout, and accept at
most a 1 MiB response. Local barcode hits do not make an OFF request.

`.env` sets `DATABASE_URL` for `cargo run`/`cargo test`. If another Postgres is
bound to port 5432 with different credentials, integration tests fail to
connect. Either stop the conflicting container or override `DATABASE_URL` per
command.

## Backend

Run:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just migrate-backend
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just dev-backend
```

The backend listens on port `3001` by default.

Build:

```bash
just build-backend
```

Test:

```bash
just test-backend
```

See [testing.md](testing.md) for integration tests and coverage.

## Frontend

The active frontend is the Elm app in `frontend-web/`.

Run:

```bash
just dev-frontend
```

By default this serves `http://localhost:1234` and proxies `/api/*` to
`http://localhost:3001`. Override the API target and port directly with Vite:

```bash
cd frontend-web
API_TARGET=http://localhost:3001 npm run dev -- --host 127.0.0.1 --port 1235
```

Build:

```bash
just build-frontend
```

Test:

```bash
just test-frontend
```

Format and review:

```bash
just format-frontend
just check-frontend-review
just check-frontend-line-length
```

## README screenshots

The feature screenshots in `docs/images/readme/` are generated from the local
development database. Start the app with `just dev`, then run:

```bash
just screenshots
```

The capture script drives Chrome through the DevTools protocol, captures the
same states in light and dark mode, and writes them to `light/` and `dark/`
subdirectories. It expects Chrome or Chromium; set `CHROME=/path/to/chrome` if
it cannot find one. Use `CALCO_URL` to capture from a different frontend
address and `CALCO_SCREENSHOT_DATE` to choose the diary date used in the shots.

## Database Migrations

Migrations live in:

```text
backend/migrations
```

Run migrations separately from app startup:

```bash
DATABASE_URL=postgres://calco:calco@localhost:5432/calco just migrate-backend
```

The current migration set is a squashed baseline. `just migrate-backend`
uses `sqlx migrate run --ignore-missing` and the baseline SQL is written to
tolerate local databases that already have the previous embedded schema, so
running it records the new baseline without recreating existing tables.

## Internationalization

Frontend copy is translated at compile time via
[i18n-to-elm](https://github.com/dragonwasrobot/i18n-to-elm) (pinned to `v0.5.0`).

- `frontend-web/i18n/en_US.json` is the hand-edited source of truth: one flat
  object of strict PascalCase keys, with `{0}`, `{1}` holes for interpolation.
- `frontend-web/generated/Translations/` is generated Elm. It is **committed**
  and must never be hand-edited or reformatted.
- Regenerate after editing the JSON:

  ```bash
  just i18n
  ```

  The recipe builds and caches the `i18n2elm` escript on first run (needs
  network once), then runs offline.

- Render strings through the `I18n.t` seam in `frontend-web/src/I18n.elm`:

  ```elm
  import I18n
  import Translations.Ids exposing (TranslationId(..))

  Element.text (I18n.t TidNavDiary)
  Element.text (I18n.t (TidTitleAddToMealSlot (MealSlot.label slot)))
  ```

  Note: Elm imports `TranslationId(..)`, not individual constructors.

`en_US` is the only locale. `generated/` is a second Elm source directory and is
excluded from `elm-format` and `elm-review`; `src`/`tests` stay formatted normal
Elm. Assistant output language is handled separately in the backend system
prompt (`backend/src/assistant/infra/food_draft/prompt.rs`), not by
this pipeline.

## Verification

Reliable current checks:

```bash
just test
just test-backend
just test-frontend
just build-frontend
```

Frontend quality gates, in order, before committing frontend changes:

```bash
just check-frontend-line-length
just check-frontend-review
just test-frontend
just format-frontend
```

## Import Operations

Imports are run from CLI tooling in two locations:

- **Data sources** (`tools/importers/data-sources/`) — public food datasets via the catalog import API.
- **Personal data** (`tools/importers/personal-data/`) — user data from other apps via user-facing APIs.

Public catalog imports require a running, migrated backend and an admin
`calco_session` token. To upload the existing processed merged catalog JSONL:

```bash
CALCO_API_URL=http://127.0.0.1:3001/api \
CALCO_SESSION_TOKEN=<admin_session_cookie_value> \
just -f tools/justfile data-sources-upload merged data
```

See [imports.md](imports.md) for full catalog workflows and
[personal-data-import.md](personal-data-import.md) for the MyFitnessPal import
workflow.
