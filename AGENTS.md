# Agent Configuration

## Current Codebase Shape

- Backend: Rust 2024, axum, sqlx, PostgreSQL migrations run with `sqlx-cli`.
- Frontend: React 19, Vite 6, TypeScript, Tailwind CSS v4, shadcn-style local UI components.
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
cd frontend && pnpm test
```

### Via just

```bash
just frontend-test
```

### Notes

- Tests live in `frontend/src/__tests__/`.
- Vitest is configured by `frontend/vitest.config.ts`.
Run all tests:

```bash
just test
```

Or run the package commands directly:

```bash
cd backend && cargo test
cd frontend && pnpm test
```

## Build Commands

```bash
just backend-build
just frontend-build
just build
```

## Development Commands

```bash
just up
just db-wait
just backend-dev
just frontend-dev
```

`backend-dev` runs `cargo run --manifest-path backend/Cargo.toml`. The backend requires `DATABASE_URL` to be set and connects to PostgreSQL before serving.
