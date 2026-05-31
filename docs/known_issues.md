# Known Issues

Items below are acknowledged but deprioritized given the current scale (tens of users, trusted homelab deployment). Revisit if user count grows or the app is exposed beyond a small known group.

## Concurrency

### TOCTOU on admin bootstrap
`create_bootstrap_admin` (backend/src/application/auth.rs:75) checks `admin_exists()` and then inserts. Two concurrent requests can both pass the check, producing multiple admins. No DB constraint enforces a single admin.

Mitigation if ever needed: add `CREATE UNIQUE INDEX ON identities ((role)) WHERE role = 'admin'` and map the unique-violation to `AdminAlreadyExists`.

### TOCTOU on username uniqueness
`admin_create_user` (backend/src/application/auth.rs:222) checks the username, then inserts. The `identities.username` unique constraint catches the race, but the violation surfaces as a `Database(...)` 500 instead of a clean `UsernameTaken` 409.

Mitigation if ever needed: catch the unique-violation and map to `UsernameTaken`.

### Non-atomic reads of food logs
`PostgresFoodLogRepository::find_by_id` / `find_by_user_and_range` (backend/src/infrastructure/postgres/food_log.rs:124, 146) fetch the log header and the nutrient snapshots in separate non-transactional statements. A concurrent `update_food_log` between the two reads can return a log header from one version with snapshots from another.

Mitigation if ever needed: single join, or wrap reads in a `REPEATABLE READ` transaction.

## Import pipeline

### Source fields dropped during conversion
Each converter projects the source dataset down to a narrow set of fields (`source`, `source_id`, `name`, `brand`, `category`, `serving_size_g`, plus mapped nutrients). Anything else in the source row is discarded, and `staging_*.raw_payload` is hardcoded to `None` in `interfaces/http/import.rs`, so there is no fallback either.

Examples currently dropped:
- **USDA**: `gtinUpc` (barcode for branded items), `scientificName`, `ndbNumber`, `dataType`, `publicationDate`, `ingredients`, `dataSource`.
- **OFF**: `ingredients_text`, `allergens`, `additives_tags`, `nova_group`, `nutriscore_grade`, `ecoscore_grade`, `labels`, `packaging`, image URLs, `*_serving` nutrient variants.
- **IFCT**: any column not listed in `nutrient_mapping/ifct2017_codes.json` (scientific name, edible portion, refuse, water content, regional names).

Recovery is by re-running the converters against the raw archives in `data/raw/`, so no data is permanently lost — but adding any of these to the product model is a deliberate schema + domain change, not a "flip a flag" operation. Each field needs: a column on `products` (or a side table), a domain field, a converter mapping, a `FoodRow` field on the HTTP boundary, and a commit-SQL projection.

Mitigation if ever needed: pick the specific fields worth surfacing (likely `ingredients_text` / `allergens` for OFF), then thread them through domain → staging → products in one go.

## Tooling / Test Commands

### Frontend package-manager commands are mixed
The repository has `frontend/pnpm-lock.yaml` and `frontend/pnpm-workspace.yaml`, but `justfile` uses `npm install`, `npm run dev`, `npm run build`, and `npm run test` for frontend recipes. Direct developer commands elsewhere generally use `pnpm`.

Mitigation: standardize the just recipes on `pnpm` if pnpm is the intended package manager.

### E2E test recipe is stale
`justfile` still defines `frontend-e2e` as `cd frontend && npx playwright test`, and `just test` depends on it. The current repository does not include `frontend/playwright.config.ts`, `frontend/e2e/`, `frontend/tsconfig.e2e.json`, or `@playwright/test` in `frontend/package.json`.

Mitigation: either restore the Playwright setup and dependency, or remove `frontend-e2e` from `just test`. Until then, run `just backend-test` and `just frontend-test` separately for reliable local verification.

### Backend migration recipe is stale
`justfile` defines `backend-migrate` as `cargo run --manifest-path backend/Cargo.toml --bin migrate`, but the backend manifest does not define a `migrate` binary. Migrations are currently embedded and run by the backend on startup.

Mitigation: remove the recipe or replace it with a command that starts the backend against the target database.
