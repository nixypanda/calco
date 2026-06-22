# CalCo — Command runner
#
# Usage: nix develop -c just <command>
# See https://github.com/casey/just

# ──────────────────────────────────────────────
# Database
# ──────────────────────────────────────────────

# Start PostgreSQL
up:
    docker compose up -d

# Stop PostgreSQL
down:
    docker compose down

# Reset database (destroy + recreate)
db-reset: down
    docker compose down -v
    docker compose up -d
    @echo "Waiting for PostgreSQL to be ready..."
    @until docker compose exec -T postgres pg_isready -U calco > /dev/null 2>&1; do sleep 1; done
    @echo "PostgreSQL is ready."

# Wait for PostgreSQL to accept connections
db-wait:
    @until docker compose exec -T postgres pg_isready -U calco > /dev/null 2>&1; do sleep 1; done
    @echo "PostgreSQL is ready."

# Open psql shell
db-shell:
    docker compose exec postgres psql -U calco -d calco

# ──────────────────────────────────────────────
# Backend
# ──────────────────────────────────────────────

# Run backend in dev mode (auto-reload)
backend-dev:
    cargo run --manifest-path backend/Cargo.toml

# Build backend
backend-build:
    cargo build --manifest-path backend/Cargo.toml

# Format backend Rust sources
backend-format:
    cargo fmt --manifest-path backend/Cargo.toml --all --check

# Run backend tests
backend-test:
    cargo nextest run --manifest-path backend/Cargo.toml

# Run backend coverage
backend-coverage:
    cargo llvm-cov nextest --manifest-path backend/Cargo.toml

# Run backend migrations
backend-migrate:
    cd backend && DATABASE_URL="${DATABASE_URL:-postgres://calco:calco@localhost:5432/calco}" sqlx migrate run --ignore-missing

# ──────────────────────────────────────────────
# Frontend (Web)
# ──────────────────────────────────────────────

# Build Elm frontend-web
frontend-web-build:
    cd frontend-web && npm run build

# Run Elm frontend-web locally
frontend-web-dev: frontend-web-build
    cd frontend-web && npm run dev

# Format Elm frontend-web sources
frontend-web-format:
    cd frontend-web && elm-format --yes src tests

# Report Elm source lines over 100 columns
frontend-web-line-length:
    @if rg -n ".{101,}" frontend-web/src frontend-web/tests; then \
        echo "Elm lines above 100 columns found."; \
        exit 1; \
    else \
        echo "Elm line length check passed."; \
    fi

# Run Elm frontend-web review
frontend-web-review:
    cd frontend-web && elm-review

# Backward-compatible alias
frontend-web-lint: frontend-web-review

# Run Elm frontend-web tests
frontend-web-test:
    cd frontend-web && elm-test

# ──────────────────────────────────────────────
# Combined
# ──────────────────────────────────────────────

# Start both backend and frontend in dev mode (requires db up)
dev: db-wait
    @echo "Starting backend and frontend..."
    (cd backend && cargo run) &
    (cd frontend-web && npm run dev) &
    wait

# Build everything
build: backend-build frontend-web-build

# Run all tests
test: backend-test frontend-web-test

# ──────────────────────────────────────────────
# Data sources import pipeline
# ──────────────────────────────────────────────

# Lint and type-check data sources import tools
data-sources-check:
    cd tools/importers/data-sources && uv run ruff check src/ && uv run ty check src/

# Dry-run fetch for IFCT and INDB to verify CLI works
data-sources-dry-run:
    cd tools/importers/data-sources && CALCO_DATA_DIR=/tmp/calco-import-dry-run uv run python -m calco_import --dry-run fetch ifct && CALCO_DATA_DIR=/tmp/calco-import-dry-run uv run python -m calco_import --dry-run fetch indb

# ──────────────────────────────────────────────
# Personal data import tools
# ──────────────────────────────────────────────

# Lint and type-check personal data import tools
personal-data-check:
    cd tools/importers/personal-data && uv run ruff check . && uv run ty check .

# Run personal data import tests
personal-data-test:
    cd tools/importers/personal-data && uv run python -m unittest discover -s . -p 'test_*.py'

# ──────────────────────────────────────────────
# Misc
# ──────────────────────────────────────────────

# Show help
default:
    @just --list
