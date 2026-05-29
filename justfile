# CalCo — Command runner
#
# Usage: just <command>
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

# Run backend tests
backend-test:
    cargo test --manifest-path backend/Cargo.toml

# Run backend migration (create/run)
backend-migrate:
    cargo run --manifest-path backend/Cargo.toml --bin migrate

# ──────────────────────────────────────────────
# Frontend
# ──────────────────────────────────────────────

# Install frontend dependencies
frontend-setup:
    cd frontend && npm install

# Run frontend dev server
frontend-dev:
    cd frontend && npm run dev

# Build frontend for production
frontend-build:
    cd frontend && npm run build

# Run frontend tests
frontend-test:
    cd frontend && npm run test

# Run frontend e2e tests
frontend-e2e:
    cd frontend && npx playwright test

# ──────────────────────────────────────────────
# Combined
# ──────────────────────────────────────────────

# Start both backend and frontend in dev mode (requires db up)
dev: db-wait
    @echo "Starting backend and frontend..."
    (cd backend && cargo run) &
    (cd frontend && npm run dev) &
    wait

# Build everything
build: backend-build frontend-build

# Run all tests
test: backend-test frontend-test frontend-e2e

# ──────────────────────────────────────────────
# Misc
# ──────────────────────────────────────────────

# Show help
default:
    @just --list
