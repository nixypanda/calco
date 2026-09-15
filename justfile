# CalCo — Command runner
#
# Enter `nix develop` once, then run `just <command>`.

set shell := ["bash", "-euo", "pipefail", "-c"]

default_database_url := "postgres://calco:calco@localhost:5432/calco"
default_calco_config_file := justfile_directory() + "/assistant-config/groq.toml"

default:
    @just --list

# Enter the reproducible development environment.
shell:
    nix develop

# Start the database, backend, and frontend development servers.
dev: db-up db-wait
    @echo "Starting backend and frontend..."
    (just dev-backend) &
    (just dev-frontend) &
    wait

# Build all projects.
build: build-backend build-frontend

# Run all tests.
test: test-backend test-frontend

# Format all source files in place.
format: format-backend format-frontend

# Check the backend and frontend.
check: check-backend check-frontend

# Run all coverage reports.
coverage: coverage-backend coverage-frontend

# Start PostgreSQL.
db-up:
    docker compose up -d

# Stop PostgreSQL.
db-down:
    docker compose down

# Reset the database (destroy and recreate it).
db-reset: db-down
    docker compose down -v
    docker compose up -d
    @echo "Waiting for PostgreSQL to be ready..."
    @until docker compose exec -T postgres pg_isready -U calco > /dev/null 2>&1; do sleep 1; done
    @echo "PostgreSQL is ready."

# Wait for PostgreSQL to accept connections.
db-wait:
    @until docker compose exec -T postgres pg_isready -U calco > /dev/null 2>&1; do sleep 1; done
    @echo "PostgreSQL is ready."

# Open a PostgreSQL shell.
db-shell:
    docker compose exec postgres psql -U calco -d calco

# Run the backend in development mode.
dev-backend:
    DATABASE_URL="${DATABASE_URL:-{{ default_database_url }}}" \
        CALCO_CONFIG_FILE="${CALCO_CONFIG_FILE:-{{ default_calco_config_file }}}" \
        cargo run --manifest-path backend/Cargo.toml

# Build the backend.
build-backend:
    cargo build --manifest-path backend/Cargo.toml

# Run backend tests.
test-backend:
    cargo test --manifest-path backend/Cargo.toml

# Format backend Rust sources.
format-backend:
    cargo fmt --manifest-path backend/Cargo.toml --all

# Run all backend checks.
check-backend: check-backend-format test-backend

check-backend-format:
    cargo fmt --manifest-path backend/Cargo.toml --all --check

# Run backend coverage.
coverage-backend:
    cargo llvm-cov --manifest-path backend/Cargo.toml

# Run backend migrations.
migrate-backend:
    cd backend && DATABASE_URL="${DATABASE_URL:-{{ default_database_url }}}" sqlx migrate run --ignore-missing

# Run the frontend development server.
[working-directory("frontend-web")]
dev-frontend:
    npm run dev

# Build the frontend.
[working-directory("frontend-web")]
build-frontend:
    npm run build

# Run frontend tests.
[working-directory("frontend-web")]
test-frontend:
    elm-test

# Format frontend Elm sources.
[working-directory("frontend-web")]
format-frontend:
    elm-format --yes src tests

# Run all frontend checks.
check-frontend: check-frontend-format check-frontend-line-length check-frontend-review build-frontend test-frontend

check-frontend-format:
    elm-format --validate frontend-web/src frontend-web/tests

check-frontend-line-length:
    @if rg -n '.{101,}' frontend-web/src frontend-web/tests; then \
        echo "Elm lines above 100 columns found."; \
        exit 1; \
    else \
        echo "Elm line length check passed."; \
    fi

[working-directory("frontend-web")]
check-frontend-review:
    elm-review

# Run frontend coverage.
[working-directory("frontend-web")]
coverage-frontend:
    npm run coverage

# Lint and type-check data-source import tools.
[working-directory("tools/importers/data-sources")]
check-data-sources:
    uv run ruff check src/
    uv run ty check src/

# Dry-run IFCT and INDB fetching to verify the importer CLI.
[working-directory("tools/importers/data-sources")]
dry-run-data-sources:
    CALCO_DATA_DIR=/tmp/calco-import-dry-run uv run python -m calco_import --dry-run fetch ifct
    CALCO_DATA_DIR=/tmp/calco-import-dry-run uv run python -m calco_import --dry-run fetch indb

# Lint, type-check, and test personal-data import tools.
check-personal-data: check-personal-data-static test-personal-data

[private]
[working-directory("tools/importers/personal-data")]
check-personal-data-static:
    uv run ruff check .
    uv run ty check .

# Run personal-data import tests.
[working-directory("tools/importers/personal-data")]
test-personal-data:
    uv run python -m unittest discover -s . -p 'test_*.py'
