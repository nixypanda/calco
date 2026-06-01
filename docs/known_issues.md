# Known Issues

Items below are acknowledged but deprioritized given the current scale (tens of
users, trusted homelab deployment). Revisit if user count grows or the app is
exposed beyond a small known group.

## Concurrency

### Non-atomic reads of food logs

`PostgresFoodLogRepository::find_by_id` / `find_by_user_and_range`
(backend/src/nutrition/infrastructure/postgres/food_log.rs:109, 130) fetch the log header
and the nutrient snapshots in separate non-transactional statements. A
concurrent `update_food_log` between the two reads can return a log header from
one version with snapshots from another.

Mitigation if ever needed: single join, or wrap reads in a `REPEATABLE READ`
transaction.

## Import pipeline

### Source fields dropped during conversion

Each converter projects the source dataset down to a narrow set of fields
(`source`, `source_id`, `barcode`, `name`, `brand`, `categories`,
`serving_size_g`, plus mapped nutrients and servings). Anything else in the
source row is discarded, and
`staging_*.raw_payload` is hardcoded to `None` in `import/interfaces/http.rs`,
so there is no fallback either.

Examples currently dropped:

- **USDA SR**: `scientificName`, `ndbNumber`, source-specific metadata, and
  fields not emitted by `tools/importers/convert_usda_sr.py`.
- **OFF**: `ingredients_text`, `allergens`, `additives_tags`, `nova_group`,
  `nutriscore_grade`, `ecoscore_grade`, `labels`, `packaging`, image URLs,
  `*_serving` nutrient variants.
- **IFCT**: any column not listed in `nutrient_mapping/ifct2017_codes.json`
  (scientific name, edible portion, refuse, water content, regional names).

Recovery is by re-running the converters against the raw archives in
`data/raw/`, so no data is permanently lost — but adding any of these to the
product model is a deliberate schema + domain change, not a "flip a flag"
operation. Each field needs: a column on `products` (or a side table), a domain
field, a converter mapping, an import DTO field on the HTTP boundary, and a
commit-SQL projection.

Mitigation if ever needed: pick the specific fields worth surfacing (likely
`ingredients_text` / `allergens` for OFF), then thread them through domain →
staging → products in one go.

## Domain modeling

These are DDD violations identified in the backend. None affect correctness
today, but they erode the boundaries the hexagonal layout is supposed to
enforce. Listed roughly by severity.

### `sqlx::Error` is part of every domain error enum

`NutritionError`, `AuthError`, and `ImportError` each have a
`Database(#[from] sqlx::Error)` variant
(`backend/src/nutrition/domain/error.rs`, `backend/src/auth/domain.rs`,
`backend/src/import/domain.rs`). The domain layer is the inner ring and should
not depend on the DB driver — right now `domain/` cannot compile without sqlx,
and every consumer of a domain error transitively pulls it in.

Mitigation if ever needed: define an opaque `RepositoryError` (or per-trait
error) in domain, and have the postgres adapters map `sqlx::Error` into it
before returning.

## Application layer

The application layer earns its keep on the write paths (auth flows,
log_item, create_meal, custom-food create/update, import staging) —
anything that orchestrates multiple repos or assembles a domain aggregate from
looked-up dependencies. The items below are about the parts that don't, plus
inconsistencies in how the layer is shaped.

### Passthroughs moved into HTTP handlers

The old catalog service passthroughs are gone; catalog handlers now call
`product_repo`, `nutrient_repo`, and `unit_repo` directly
(`nutrition/interfaces/http/catalog.rs`). The same mixed boundary still exists
in other places: `summary_handler` calls `summary_repo.get_summary(...)`
directly (`nutrition/interfaces/http/food_log.rs`), import error lookup calls
`import_repo.get_errors(...)` directly, and meal list/detail are handled
outside `MealServices`.

Mitigation if ever needed: make this an explicit convention. Either handlers may
call repos for read-only passthroughs, or every use case goes through a service.

### Duplicate / near-duplicate logic

- `ImportServices::stage_foods` / `stage_nutrients` / `stage_servings`
  (`import/application.rs`) are three ~50-line methods that vary only in the
  per-row validation predicate.

Mitigation if ever needed: a generic `stage<T>(...)` parameterized by a
validator closure for the import staging trio.

### Domain validation living in application

`ImportServices::stage_*` per-row validation (`source.is_empty()`,
`nutrient_code.is_empty()`, `quantity <= 0`, `grams <= 0`) is invariant-checking
on staged rows. The staged types (`StagedImportProduct`, `StagedImportNutrient`,
`StagedImportServing`) own those invariants — application should be collecting
`Ok`/`Err` from a domain constructor, not running the checks itself.

Mitigation if ever needed: `StagedImportProduct::try_new(...)` / equivalents on
each staged type, returning a domain error the service maps once.

### Vestigial / undocumented

- `UpdateFoodInput` / `UpdateMealInput` use `Option<Option<T>>` for PATCH-style
  "absent vs explicit-null vs value" with no doc explaining the convention.

Mitigation if ever needed: either a `Patch<T>` enum or a doc comment on the
PATCH input structs.

### Mock-by-singleton test smell

The unit-test mocks for `ProductRepository` and `MealRepository`
(`nutrition/application/{food_log,meal}.rs` `#[cfg(test)]` blocks) return the
same product/meal for _any_ id. Tests work around this by hardcoding
`Uuid::nil()` everywhere they create or look up an entity. The mocks aren't
actually testing the repository path — they're testing "service called the
repo."

Mitigation if ever needed: replace with `HashMap<Id, Entity>`-backed mocks so
tests describe the data they expect to find.

## Backend cleanup

### Error response shapes are duplicated per HTTP module

Nutrition handlers share one `ErrorResponse` and one
`IntoResponse for NutritionError` impl in
`nutrition/interfaces/http/mod.rs`. Auth still defines its own
`AuthErrorResponse`, `ErrorBody`, and `auth_error_to_status_and_code` in
`auth/interfaces/http.rs`, and import has its own mappings. The shapes are
nearly identical.

Mitigation if ever needed: lift the shared `ApiError` / `ErrorResponse` and
`IntoResponse` impl to a crate-level HTTP module, then implement
`From<AuthError>` / `From<ImportError>` for it. Keep module-specific status
codes only where the public API behavior genuinely differs (auth has more
distinct status codes than nutrition).

### General-purpose errors should stay at the outer edge

Application/domain errors are structured because handlers need to distinguish
validation, not-found, forbidden, and internal failures. Replacing those with
`anyhow::Error` would make HTTP mapping and tests less explicit.

Mitigation if ever needed: use `anyhow` only for outer glue code such as
startup/config/server wiring or CLI-style import tools, where callers only need
contextual failure reporting and do not branch on concrete error variants.
