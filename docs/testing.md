# Testing

## Layout

Two kinds of backend tests:

```text
backend/src/**/*.rs       inline #[cfg(test)] unit tests (domain + application, mocked repos)
backend/tests/*.rs        integration tests (real HTTP router, real Postgres)
backend/tests/common/     shared harness (see below)
frontend-web/tests/*.elm  Elm frontend unit tests
```

Integration tests cover the HTTP lifecycle of each entity end-to-end:

```text
tests/product_lifecycle.rs   custom-food CRUD + search + auth required
tests/diary_lifecycle.rs     food log CRUD + summary
tests/meal_lifecycle.rs      meal CRUD + /meals/{id}/nutrients
tests/cross_entity.rs        product -> meal -> log -> summary wiring
tests/import_lifecycle.rs    admin import flow + error path
```

## How Integration Tests Work

- The crate exposes a library (`backend/src/lib.rs`) with `build_router(pool, config)`. `main.rs` is a thin shim that calls it; tests call the same function.
- Each test is annotated `#[sqlx::test]`. sqlx provisions a fresh database per test from a migrated template, hands the test a `PgPool`, and drops the database when the test passes.
- The router is driven in-process via `tower::ServiceExt::oneshot` — no socket, no port binding.
- The shared harness (`tests/common/mod.rs`) provides `app(pool)`, `bootstrap_admin`, `create_user_session`, and JSON request/response helpers.

## Required Environment

A Postgres reachable as `DATABASE_URL` whose user has `CREATEDB` privilege.

Project default (matches `docker-compose.yml`):

```text
DATABASE_URL=postgres://calco:calco@localhost:5432/calco
```

Bring it up with:

```bash
just up
just db-wait
```

## Running

Standard:

```bash
cd backend && cargo test
```

Single integration file while iterating:

```bash
cd backend && cargo test --test product_lifecycle
```

Surface handler logs from a failing test:

```bash
RUST_LOG=info cargo test --test diary_lifecycle -- --nocapture
```

Elm frontend tests:

```bash
just frontend-web-test
```

Or directly:

```bash
cd frontend-web && elm-test
```

## Running With Nextest

Nextest runs each test in its own process, which suits `#[sqlx::test]` well. Each test still gets its own database, so parallelism is safe.

```bash
cargo install cargo-nextest --locked
cd backend && cargo nextest run
```

Watch `max_connections` if the suite grows. Each test builds a pool of 5; Postgres allows 100 by default. If `too many connections` shows up, cap parallelism:

```bash
cargo nextest run --test-threads 8
```

## Coverage

Coverage is produced by `cargo-llvm-cov`, which integrates with nextest.

Install once:

```bash
cargo install cargo-llvm-cov --locked
rustup component add llvm-tools-preview
```

Terminal summary:

```bash
cd backend && cargo llvm-cov nextest
```

Browsable HTML report:

```bash
cd backend && cargo llvm-cov nextest --html --open
```

LCOV for CI / IDE integrations:

```bash
cd backend && cargo llvm-cov nextest --lcov --output-path lcov.info
```

Exclude the test harness from coverage math:

```bash
cd backend && cargo llvm-cov nextest --ignore-filename-regex 'tests/'
```

Instrumented builds use a separate `target/llvm-cov-target/` directory, so the first run recompiles from scratch. Subsequent runs are incremental.

## Gotchas

- `.env` sets `DATABASE_URL` for `cargo run`/`cargo test`; if another Postgres is bound to port 5432 with different credentials, integration tests fail to connect. Either stop the conflicting container or override `DATABASE_URL` per command.
- Catalog `Source` values are uppercase enums (`OFF`, `USDA`, `IFCT`, `USER`). Tests that stage imports must use those exact codes.
- `GET /meals/{id}/nutrients?amount=X` scales by the meal's `total_quantity`. For predictable assertions, set `total_quantity` to match the sum of component weights.
