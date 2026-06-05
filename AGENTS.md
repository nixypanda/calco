# Agent Configuration

## Current Codebase Shape

- Backend: Rust 2024, axum, sqlx, PostgreSQL migrations run with `sqlx-cli`.
- Frontend: Elm 0.19.1, elm-ui, elm-test.
- Database: PostgreSQL via `docker-compose.yml`.
- Test runner commands are defined in `justfile`.

## Backend Rust Tests

```bash
# Run all backend tests
cd backend && cargo test

# Run specific test
cd backend && cargo test test_log_food_success

# Run tests for a specific module
cd backend && cargo test nutrition::domain::food_log
```

### Via just

```bash
just backend-test
```

### Notes

- Backend tests are inline under `#[cfg(test)] mod tests { ... }`.
- Domain and application tests use manual mock repositories.
- Migrations live in `backend/migrations` and are run explicitly with `just backend-migrate`.

## Frontend Unit Tests

```bash
cd frontend-web && elm-test
```

### Via just

```bash
just frontend-web-test
```

### Notes

- Tests live in `frontend-web/tests/`.
- Elm tests are pure unit tests (no DOM, no mocks).

### Frontend Quality Gates

Run these in order before committing frontend changes:

```bash
just frontend-web-line-length
just frontend-web-review
just frontend-web-test
just frontend-web-format
```

Run all tests:

```bash
just test
```

Or run the package commands directly:

```bash
cd backend && cargo test
cd frontend-web && elm-test
```

## Build Commands

```bash
just backend-build
just frontend-web-build
just build
```

## Development Commands

```bash
just up
just db-wait
just backend-dev
just frontend-web-dev
```

`backend-dev` runs `cargo run --manifest-path backend/Cargo.toml`. The backend requires `DATABASE_URL` to be set and connects to PostgreSQL before serving.
