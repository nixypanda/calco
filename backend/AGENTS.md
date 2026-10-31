# Backend Agent Instructions

This directory contains the Rust backend. Also read the repository root
`AGENTS.md` and `../docs/backend.md` before changing backend behavior.

## Shape

- Rust 2024 service using axum, sqlx, and PostgreSQL.
- `src/lib.rs` is the app composition root (`AppState`, `build_app_state`,
  `build_router`).
- Code is organized by bounded context first, then layer:
  `auth/`, `catalog/`, `journal/`, `import/`, and `assistant/`.
- `infra` is always a directory with `mod.rs`. One PostgreSQL repository uses
  `infra/pg.rs`; multiple repositories use `infra/pg/` with one module per
  repository. Non-Postgres adapters live under `infra/`.
- `api` is always a directory with `mod.rs`. A single HTTP surface uses
  `api/http.rs`; a split surface uses `api/http/` with a `mod.rs`. Bare
  `api.rs` files are not allowed.
- Normal dependency direction is:

```text
api/http -> app -> domain
infra/pg -> domain ports
```

## Domain Rules

- Keep repository traits in `domain`; PostgreSQL implementations belong under
  `infra/pg.rs` or `infra/pg/`.
- Repositories are persistence/query ports, not business-action services. Use
  storage-shaped names such as `create`, `find_by_*`, `list_by_*`, `update`,
  and `delete`.
- Business decisions and state transitions belong in domain or app code before
  handing decided state to repositories.
- Food logs snapshot nutrients at log time. Summaries should read
  `food_log_nutrients`, not current catalog nutrients.
- Normal food-tracking data is keyed by `user_profiles.id`, not
  `identities.id`.
- The import repository is an exception for the import workflow. Do not use its
  patterns as precedent for normal domain repositories.

## Migrations

- Migrations live in `migrations/`.
- Run migrations explicitly with:

```bash
just migrate-backend
```

## Tests

Backend unit tests are usually inline under `#[cfg(test)] mod tests`.
Integration tests live in `tests/` and use `#[sqlx::test]`.

Run from the repository root:

```bash
just test-backend
```

Or directly:

```bash
cd backend && cargo test
cd backend && cargo test --test product_lifecycle
cd backend && cargo test journal::food_log::domain
```

Integration tests require PostgreSQL reachable via `DATABASE_URL`. The project
default is:

```text
postgres://calco:calco@localhost:5432/calco
```

Bring it up with:

```bash
just db-up
just db-wait
```
