# Agent Configuration

## Current Codebase Shape

- Backend: Rust 2024, axum, sqlx, PostgreSQL migrations embedded in the binary.
- Frontend: React 19, Vite 6, TypeScript, Tailwind CSS v4, shadcn-style local UI components.
- Database: PostgreSQL via `docker-compose.yml`.
- Test runner commands are defined in `justfile`, but see the e2e note below.

## Backend Rust Tests

```bash
# Run all backend tests
cd backend && cargo test

# Run specific test
cd backend && cargo test test_log_food_success

# Run tests for a specific module
cd backend && cargo test domain::food_log
```

### Via just

```bash
just backend-test
```

### Notes

- Backend tests are inline under `#[cfg(test)] mod tests { ... }`.
- Domain and application tests use manual mock repositories.
- The app runs migrations on startup from `backend/src/infrastructure/postgres/migrations`.

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
- The frontend currently has no committed Playwright config or `frontend/e2e/` directory.

## Playwright / E2E Status

`justfile` still contains `frontend-e2e` and includes it in `just test`, but the current frontend manifest does not include `@playwright/test`, and these files are not present:

- `frontend/playwright.config.ts`
- `frontend/e2e/`
- `frontend/tsconfig.e2e.json`

Until e2e support is restored, use:

```bash
just backend-test
just frontend-test
```

or run the package commands directly:

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
