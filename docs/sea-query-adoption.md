# Sea-query Adoption

CalCo uses `sea-query` 1.0 for PostgreSQL repository query construction. The
goal is better ergonomics for dynamic filters, CRUD, upserts, and array binds,
without hiding the PostgreSQL-specific SQL where that would make the code less
clear.

Dependencies:

- `sea-query` 1.0.2
- `sea-query-sqlx` 0.9.1
- `sqlx` 0.9.0
- PostgreSQL backend only

## Converted

- Auth: sessions, API keys, identities, and user profiles.
- Food logs: dynamic filters, snapshot loading, list queries, CRUD, and the
  PostgresQueryBuilder-based nutrient helper (multi-row INSERT ... VALUES).
- Goals and diary preferences: all repository queries.
- Meals: parent and component create/read/list/update/delete.
- Catalog: product CRUD, nutrient/serving loads, `existing_ids`,
  barcode/custom-product queries, search candidate queries, category counts,
  the external-upsert insert and identity resolve, nutrient-ID lookup,
  nutrient/unit repositories, and PostgresQueryBuilder-based child helpers
  (multi-row INSERT ... VALUES).

Every converted query is built with `sea-query`, rendered with
`PostgresQueryBuilder`, and executed through parameterized `sqlx` calls using
`AssertSqlSafe` only for builder-generated SQL.

## Remaining raw SQL

### Import repository

`backend/src/import/infra/pg.rs`

Functions: `create_job`, `find_job`, `stage_foods`, `stage_nutrients`,
`stage_servings`, `prepare_commit`, `finish_commit`, `get_errors`,
`lock_pending_job`, `lock_job_status`, `add_error_in_tx`.

The import repository is the admin bulk-ingestion and anti-corruption workflow.
It relies on per-row staging upserts, row-level error recording,
`SELECT ... FOR UPDATE` locking, status transitions, and transaction-heavy
commit logic. Sea-query would not remove that complexity and could obscure the
locking and error-handling semantics.

### Catalog external upsert

`backend/src/nutrition/catalog/infra/pg/product/mod.rs` —
`upsert_external_many`.

Two pieces remain raw:

- `LOCK TABLE products, product_nutrients, product_servings IN SHARE ROW
  EXCLUSIVE MODE` is a PostgreSQL concurrency primitive with no clean
  sea-query builder equivalent.
- `UPDATE products ... FROM (VALUES ...) AS incoming(...) ... ROW(...) IS
  DISTINCT FROM ROW(...)` is easier to read and verify as SQL. Sea-query would
  require custom expressions for the values table and row comparison.

The insert and identity-resolve parts of the same method do use sea-query.

### Migrations

`backend/migrations/*.sql`

Sea-query is a query builder, not a migration runner. These files are
historical, checksummed `sqlx` migrations; rewriting them would break migration
history.

### Tests and integration fixtures

`backend/tests/**` and inline test setup.

Raw SQL is used for seeding and asserting database state, not for repository
production queries. Converting test fixtures would add noise and couple tests
to the query builder.

## Boundary rule

Use sea-query where it clearly helps: dynamic predicates, CRUD, upserts,
PostgreSQL array binds, and ordering. Keep raw SQL only for bulk, locking, or
import workflows where builder indirection would obscure the transactional
semantics.

Fixed PostgreSQL function names such as `unnest` and `btrim` still use
`Func::cust` because sea-query has no first-class helper; these are static
identifiers, not interpolated user input.

All remaining raw production SQL is parameterized; no user input is
interpolated. The main future candidate for conversion is the import
repository, but it should be a separate, behavior-tested change because of its
staging loops, locking, and status transitions.
