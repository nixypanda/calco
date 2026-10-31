# Postgres → SQLite Migration Plan

**Status:** Agreed; ready for implementation
**Owner:** TBD
**Last updated:** 2026-10-27

## Context

CalCo currently runs on PostgreSQL via `docker-compose.yml` (local dev) and the
NixOS module (`services.postgresql`) in production. The goal is to switch the
whole stack — backend, tests, importer tooling, deployment — to SQLite.

This document is the detailed plan. It is written to be executed in order, with
explicit decision gates and a rollback path.

## Goals

- Replace PostgreSQL with SQLite across runtime, tests, tooling, and deployment.
- Preserve existing production data via a one-off migration.
- Keep the change verifiable and reversible at every step.

## Guiding principles

1. **Isolate the two failure domains.** Changing the SQL dialect and changing the
   database engine are separate risks. Do them separately so a failure can be
   attributed to one or the other.
2. **Tests are the portability oracle.** The same integration suite should pass
   against Postgres (after the refactor) and against SQLite (after the switch).
   Parameterize the test DB rather than rewriting tests twice.
3. **Freeze encodings before the migrator.** The app, the migrations, and the
   Python tooling must agree on how IDs, decimals, timestamps, and JSON are
   stored.
4. **Never destroy Postgres until SQLite is verified in production.**
5. **Preserve the public API.** IDs and decimal amounts stay **strings** on the
   wire, so the Elm frontend needs (almost) no changes.

## Resolved decisions (Phase 0)

| # | Decision | Choice |
|---|---|---|
| 1 | Production data | Preserve it. Single dump taken at cutover with writes frozen; the user base is small and no new data is expected in between. |
| 2 | Search | Rust-based scoring (portable; works on Postgres first, reused on SQLite). |
| 3 | Array columns | Normalized child tables. |
| 4a | IDs | `INTEGER PRIMARY KEY` auto-increment (SQLite rowid). No random generator, no `AUTOINCREMENT` keyword. Wire format stays string. |
| 4b | Decimal | **`f64` in Rust; remove `rust_decimal`.** Store `REAL`. Do **not** round to 3 dp. Normalize on decode; serialize amounts as strings. |
| 4c | Timestamp | `TEXT` RFC3339 (sqlx default encoding). |
| 4d | JSON | `TEXT` (`sqlx::types::Json<T>`). |
| 5 | Deployment scope | Full: dev, tests, Docker removal, NixOS module, Python tooling, docs. |
| 6 | Dev DB file | `data/calco.db` (gitignored). |
| 7 | Prod DB file | `/var/lib/calco/calco.db` via systemd `StateDirectory`. |
| 8 | Prod backup | `sqlite3 .backup` on a timer (litestream optional). |
| 9 | Concurrency | Single backend instance (SQLite is single-writer). |
| 10 | Python tooling | Port to stdlib `sqlite3` + `rapidfuzz` (already a dependency). |
| 11 | Migration runner | `sqlx-cli` (with the `sqlite` feature) in the Nix oneshot; app does not migrate on startup. |
| 12 | Cutover dump | Take a fresh production dump at cutover. |
| 13 | Search ordering | Preserve the exact current tier ordering. |
| 14 | FK semantics | Preserve current (partly lax) FK semantics; do not tighten. |

## Encoding details

### IDs — auto-increment `INTEGER PRIMARY KEY`

- Every `uuid PRIMARY KEY` becomes `id INTEGER PRIMARY KEY` (an alias for the
  built-in 64-bit `rowid`). SQLite fills it sequentially on insert: **unique by
  construction, no collisions, no generator.**
- Omit `AUTOINCREMENT`. It only prevents reuse of the last deleted rowid and
  costs an extra table write; not needed here.
- **Create flow changes.** Today the *domain* mints the UUID before insert; now
  the DB assigns it, so repositories use `RETURNING id` (SQLite ≥ 3.35) or
  `last_insert_rowid()` and hand the id back. `upsert_external_many` already
  re-queries ids by `(source, source_id)`, so external imports are unaffected.
- **Wire format unchanged:** id newtypes serialize/deserialize as **strings** in
  JSON. Paths (`/api/foods/{id}`) parse the string to `i64`. This keeps
  `Data/Food.elm`, `Data/ItemRef.elm`, `Data/FoodLog.elm`, etc. unchanged.
- Session `session_security_stamp` is a random token, not a row id — keep it as a
  random string/blob.
- **Security note:** sequential ids are guessable. All endpoints already
  authorize by the authenticated `user_id`, so this is low risk. If
  unguessable ids become a requirement, the cheapest option is UUID-as-TEXT, not
  random integers.

### Decimal — `f64`, remove `rust_decimal`

- `sqlx-sqlite` deliberately does **not** implement `rust_decimal::Decimal`
  (confirmed in `sqlx-sqlite-0.8.6`), so `Decimal` cannot round-trip.
- Decision: **replace `rust_decimal::Decimal` with `f64` throughout the domain,
  remove the `rust_decimal` dependency and the `sqlx` `rust_decimal` feature,
  and store `REAL`.**
- **Do not round to 3 decimals.** Real data disproves the "3 dp is enough"
  assumption:
  - `product_nutrients.amount_per_100g`: up to 8 decimals, magnitudes up to
    ~840,000,000.
  - 8,133 `product_nutrients` and 23,601 `food_log_nutrients` rows have more than
    3 decimals, including µg-scale values like `0.000001`.
  - One legacy `food_log_nutrients.amount` is stored with 30 decimals (a division
    artifact) — f64 naturally cleans this up.
- f64 has ~15–16 significant digits, comfortably covering the observed range.
- Normalize decoded values (e.g. round to ~12 dp) to remove float artifacts
  (`0.01` → `0.009999999...`).
- **API compatibility:** amounts stay serialized as **strings** (the Elm
  frontend decodes `amount`, `amount_per_100g`, etc. with `Decode.string`).

### Timestamp and JSON

- `chrono::DateTime<Utc>` is encoded by sqlx as RFC3339 `TEXT`; `NaiveDate` as
  `%F` `TEXT`. Both are lexicographically sortable for UTC.
- `jsonb` → `TEXT`, read/written via `sqlx::types::Json<T>`.

## What "agnostic" realistically means

The target is a **portable query layer** plus **engine-specific schema/migrations
and pool construction** (the only place the driver name appears).

### Postgres-only constructs and portable replacements

| Postgres-only thing | Portable replacement | Notes |
|---|---|---|
| `ANY($1)` on arrays | `IN (...)` via `QueryBuilder` / `json_each` | query-layer change |
| `UNNEST(...)` bulk insert | `QueryBuilder::push_values` | query-layer change |
| `gen_random_uuid()` defaults | removed; ids auto-assign | schema change |
| `NOW()` / `::INT` casts | `CURRENT_TIMESTAMP` / `CASE WHEN` | trivial |
| `DISTINCT ON` | window functions (`ROW_NUMBER`) | both engines support |
| `ROW(...) IS DISTINCT FROM ROW(...)` | column-wise `IS NOT` | catalog upsert |
| `LOCK TABLE ... SHARE ROW EXCLUSIVE` | single writer / `BEGIN IMMEDIATE` | real divergence |
| `jsonb` | `TEXT` + `sqlx::types::Json` | schema + query change |
| `text[]` (`categories`, `enabled_meal_slots`) | child tables | **applied decision** |
| `similarity()` / pg_trgm | in-Rust scoring | **applied decision** |
| `NUMERIC` / `rust_decimal` | `REAL` / `f64` | **applied decision** |

### `sqlx::Any` spike

The backend uses only runtime queries (no `query!` macros), so `sqlx::Any` could
provide one pool type across both engines during the dual run. Outcome after the
`f64` decision: `Any` is more viable (no `Decimal` obstacle), but `Any` still has
`Uuid`/type-decoding rough edges. Use it only if it makes the Phase 1 dual-run
meaningfully cheaper; otherwise keep two pool types behind the repository traits.

## Arrays → child tables (concrete schema)

```sql
CREATE TABLE product_categories (
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    category   TEXT    NOT NULL,
    PRIMARY KEY (product_id, category)
);
CREATE INDEX product_categories_category_idx ON product_categories(category);
```

- `include_categories` (product has *all*): `GROUP BY product_id HAVING COUNT(*) = :n`.
- `exclude_categories` (product has *none*): `NOT EXISTS (... category IN (...))`.
- `staging_products.categories` →
  `staging_product_categories(import_id, source, source_id, category)`.
- `diary_preferences.enabled_meal_slots` →
  `diary_preference_meal_slots(user_id, meal_slot)`, with
  `CHECK (meal_slot IN ('breakfast','lunch','dinner','snack','late_night_snack'))`
  replacing the removed `cardinality`/`<@` constraint.
- Category suggestions become
  `SELECT category, COUNT(*) FROM product_categories GROUP BY category`.

## Search — detailed design

### Current behavior that must be preserved

**Rust catalog search** (candidate fetch in
`catalog/infrastructure/postgres/product/statements.rs`; matching and
ranking in `catalog/domain/search_ranking.rs`):

1. **Scopes:** All; Custom (`source='USER'`); History (products the user has
   logged; recency first, then relevance).
2. **Match:** an empty query returns up to 50 results in ranker order (catalog
   scopes put barcode-prefix matches first); otherwise exact, prefix, or
   substring matches on name, brand, or barcode qualify, as does a
   trigram-containment fuzzy match from `rust-fuzzy-search` on name/brand at or
   above `DEFAULT_FUZZY_THRESHOLD` (currently **0.50**, inclusive). `History`
   also matches category terms.
   Search text is literal: `%` and `_` are not wildcards.
3. **Category filters:** include = superset; exclude = disjoint (see child-table
   queries above).
4. **Ordering tiers:** barcode exact → barcode prefix → name prefix → name
   substring → brand prefix → brand substring → fuzzy; then name/brand
   similarity, then normalized name; `LIMIT 50` after ranking. For `History`,
   `last_log_date DESC, last_logged_at DESC` sort before the tier tuple.
5. **Category suggestions:** fetch counts, then order prefix → substring → fuzzy
   (strictly greater than the threshold) → `COUNT(*) DESC` → similarity → name.

**Importer matching** (`generate_food_match_review.py`, via `psql`): same idea,
explicit `similarity >= 0.18` candidate threshold plus `%` (0.3).

### Chosen approach: Rust-based scoring (Option B)

- SQL generates storage-filtered candidates (scope and category filters); it
  does no text matching or ranking.
- The **pure `search_ranking` module** takes candidate rows + query text and
  returns the ordered list, reproducing the tier ordering above with
  trigram-containment similarity from `rust_fuzzy_search::fuzzy_compare` (query
  first). It now exists in `catalog/domain/search_ranking.rs`.
- Benefits: runs identically on Postgres and SQLite, is unit-testable (matching
  the repo's "pure ranking has unit tests" philosophy), and will be reused
  verbatim on SQLite.
- The Rust matcher uses trigram containment with
  `DEFAULT_FUZZY_THRESHOLD = 0.50`. Product fuzzy gates are inclusive (`>=`),
  category suggestion fuzzy gates are exclusive (`>`), and `%`/`_` are literal
  rather than wildcards. The score is asymmetric (`fuzzy_compare(query,
  candidate)`) and the crate is pinned to `=0.1.1`; upgrades require
  recalibration. Word-order matches work (`milk almond` vs `Almond Milk` about
  0.8333), and later-word fuzzy matches can appear (`chiken` vs
  `Grilled Chicken Breast` about 0.5714). Some old matches are lost
  (`vegtable` vs `other-vegetables` about 0.4444). The Python importer keeps its
  own `similarity >= 0.18` candidate threshold plus `%` (0.3).
- `FTS5` is **deferred**. The bundled SQLite is built with
  `-DSQLITE_ENABLE_FTS5`, so it can be added later purely as a fast candidate
  index while Rust keeps doing the ranking — results stay identical.
- **Python importer** matching moves to `sqlite3` + `rapidfuzz`
  (`token_sort_ratio`/`token_set_ratio` are already used in
  `data-sources/.../merge.py`).

### Search artifacts to update

- `catalog/infrastructure/postgres/product/statements.rs` — replace
  `text[]` candidate filters with child-table queries. Fuzzy matching and
  ranking SQL are already gone.
- `catalog/domain/search_ranking.rs` — **done**: pure Rust matcher and
  rankers with unit tests; reuse unchanged on SQLite.
- `tools/importers/personal-data/.../generate_food_match_review.py` — drop `psql`.
- `tools/importers/tests/harness.py` + `test_import_pipeline.py` — SQLite files,
  `sqlite3` snapshots.

## Production data (grounding facts)

- Real dumps live in `data/backups/`; the representative one is
  `calco-production-pre-off-20260729-132516-IST.dump`.
- **~10,040 products** (plus servings, nutrients, food logs).
- The dump **predates later migrations** (it still has `products.serving_size_g`).
  The migrator must run against a **restored + fully-migrated** Postgres
  (restore → `sqlx migrate run` → export), not parse the old dump directly.
- `data/processed/merged.jsonl` (~230k source rows) is the catalog feed; the
  post-merge product count is the ~10k above.

## Phase plan

### Phase 0 — Decisions

- [x] All decisions in the table above are resolved.

### Phase 1 — Remove Postgres-specific SQL, still on Postgres

Split to reduce the risk of the Phase 2 deploy.

#### 1a. Query-portability only (no schema change)

- [ ] Remove `ANY` / `UNNEST` / `NOW` / casts / `DISTINCT ON` / row-comparison /
      `LOCK` / `gen_random_uuid` dependence from the Postgres repository modules
      under `infrastructure/`.
- [ ] Deployable on Postgres with **no schema change**.

#### 1b. Schema-affecting portability (riskier)

- [ ] Normalize `categories` / `enabled_meal_slots` to child tables.
- [ ] Replace `jsonb` → JSON `TEXT`.
- [x] Introduce the Rust scoring module in
      `catalog/domain/search_ranking.rs`. The `pg_trgm` extension and
      indexes remain in place (currently unused by catalog search); drop them
      during the SQLite migration or in a separate cleanup.
- [ ] Requires a **data-preserving Postgres migration**. Deploy only with a backup.
- [ ] Redesign the Postgres-specific concurrency test in
      `tests/suites/product_repository.rs` (`LOCK TABLE … ROW EXCLUSIVE MODE`)
      around the single-writer SQLite model.

### Phase 2 — Deploy refactor on Postgres and verify

- [ ] **Back up first** (see Doubts). Phase 1b is a production schema migration.
- [ ] Run `just verify-normalization-migration` against a restored, not-yet-migrated
      copy (or the live DB before migrating). It snapshots the old columns, applies the
      Phase 1b migration, proves the child tables and `TEXT` conversions reproduce the
      pre-migration rows exactly, then rolls back without touching the database.
- [ ] Deploy the refactor on Postgres.
- [ ] Run the full test suite against Postgres.
- [ ] Confirm search behavior matches expectations.

### Phase 3 — Production backup

- [ ] `pg_dump` (schema + data) of production.
- [ ] Filesystem/volume snapshot.
- [ ] Capture the `_sqlx_migrations` state.

### Phase 4 — Build the SQLite target

> Inserted relative to the naive order: you cannot build or test the migrator
> until the SQLite schema and driver exist.

- [ ] Create the SQLite migration set in a **new directory**
      (`backend/migrations/sqlite/`), with `INTEGER PRIMARY KEY` ids, `REAL`
      decimals, `TEXT` timestamps/JSON, and child tables.
- [ ] Pool factory with `PRAGMA foreign_keys=ON`, `journal_mode=WAL`,
      `busy_timeout`.
- [ ] `Cargo.toml`: switch sqlx feature `postgres` → `sqlite`; remove
      `rust_decimal`.
- [ ] Replace `rust_decimal::Decimal` with `f64` across domain/app/interfaces;
      serialize amounts and ids as strings at the API boundary.
- [ ] Port the Python importers to `sqlite3` + `rapidfuzz`.
- [ ] Parameterize `#[sqlx::test]` / `tests/common/mod.rs` (shared-cache
      in-memory or temp file per test).

### Phase 5 — One-off Postgres → SQLite migrator

- [ ] Reads a **restored, migrated** Postgres, writes a fresh SQLite file.
- [ ] Deterministic and re-runnable (fresh file each run).
- [ ] Maps old UUIDs → new auto-increment integers per table and rewrites FKs via
      that mapping.
- [ ] Test repeatedly on synthetic data **and** the restored production dump
      (encoding/NULL/decimal edge cases).

### Phase 6 — Switch code/config/deploy to SQLite

- [ ] `backend/Cargo.toml` (sqlx `sqlite`), `backend/src/main.rs`.
- [ ] `justfile`: `db-up` / `db-wait` / `db-reset` / `db-shell` / `migrate-backend`.
- [ ] Remove Postgres from `docker-compose.yml`.
- [ ] `flake.nix`: ensure `sqlx-cli` has the `sqlite` feature.
- [ ] `nix/backend.nix` (migrations packaging).
- [ ] `nix/module.nix`: replace `services.postgresql` / `postgresqlBackup` with a
      `StateDirectory` + `sqlite3 .backup` timer; migrate oneshot uses a
      `sqlite:` URL; add `ReadWritePaths` for the DB/`-wal`/`-shm` files.
- [ ] Docs: README, root + backend `AGENTS.md`, `docs/*`.

### Phase 7 — Deploy SQLite

- [ ] **Cutover with a short maintenance window / writes frozen.** The migrator
      snapshots Postgres once; any writes during export→import are lost.

### Phase 8 — Load data in production and verify

- [ ] Stop backend → run migrator → start backend.
- [ ] Verify row counts and spot-check data.
- [ ] **Keep Postgres data intact for rollback.**

## Doubts / recommended order changes

1. **The naive "migrator before switch" order is not buildable.** The SQLite
   schema must exist before the migrator can be written or tested; Phase 4
   precedes Phase 5.
2. **Back up before the Phase 2 deploy, not only at Phase 3.** Phase 1b is a
   schema migration on production.
3. **Phase 1b is the sleeper risk.** Normalizing arrays while still on Postgres
   is a real production migration. Consider doing **1a only** on Postgres
   (deploy, verify) and deferring 1b until after the Phase 3 backup, or folding
   it into the SQLite build.
4. **Do not round decimals to 3 dp.** The data contains µg-scale values down to
   `1e-6` and one 30-decimal artifact; f64 storage handles them, rounding would
   not.
5. **`f64` migration is cross-cutting.** Removing `rust_decimal` touches the
   domain, application, interfaces, and tests — budget for it in Phase 4.
6. **Don't delete the Postgres volume on switch.** Keep it as the rollback path.
7. **Take a maintenance window for the cutover.**
8. **Python tooling is easy to forget.** It shells out to `psql`, uses
   `similarity()` / `json_agg` / `ANY(ARRAY[...])`, and creates throwaway PG
   databases.
9. **Tests must stop requiring an external service.** After the switch,
   `just test-backend` should run with no Postgres/Docker.
10. **`#[sqlx::test]` for SQLite** needs shared-cache in-memory or a temp file per
    test.
11. **Nix specifics:** writable DB dir (`StateDirectory` + `ReadWritePaths` under
    `ProtectSystem=strict`) for the DB, `-wal`, and `-shm` files; backups via
    `sqlite3 .backup` instead of `postgresqlBackup`.
12. **Search ranking is user-visible.** Calibrate the `rust-fuzzy-search`
    threshold on the real dump and keep the ranking unit tests.
13. **Keep migration directories separate during the dual run**
    (`migrations/postgres` vs `migrations/sqlite`). Do not edit already-applied PG
    migration files — sqlx checksums will break.

## Rollback

- Postgres data and volume are retained through the cutover.
- If Phase 7/8 fails: stop the SQLite backend, restore `DATABASE_URL`/deployment
  config to Postgres, restart.
- The refactor commit (Phase 1) is deployable on Postgres independently of the
  engine switch, so a failed SQLite switch does not require reverting the
  refactor.

## Definition of done

- `just test-backend` runs on SQLite with no external service; the same suite
  passed on Postgres before the switch.
- `just test-importers-e2e` passes against SQLite.
- The NixOS module deploys, migrates, backs up, and restarts cleanly against a
  SQLite file; a rollback path to Postgres is documented.
- Docs and `AGENTS.md` updated; PostgreSQL removed from `docker-compose.yml`.
- IDs and decimal amounts remain strings on the wire; the Elm frontend is
  unchanged (or changes are limited to nothing more than serialization tweaks).
