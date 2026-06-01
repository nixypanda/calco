# Known Issues

Items below are acknowledged but deprioritized given the current scale (tens of
users, trusted homelab deployment). Revisit if user count grows or the app is
exposed beyond a small known group.

## Concurrency

### TOCTOU on admin bootstrap

`create_bootstrap_admin` (backend/src/application/auth.rs:32) checks
`admin_exists()` and then inserts. Two concurrent requests can both pass the
check, producing multiple admins. No DB constraint enforces a single admin.

Mitigation if ever needed: add
`CREATE UNIQUE INDEX ON identities ((role)) WHERE role = 'admin'` and map the
unique-violation to `AdminAlreadyExists`.

### TOCTOU on username uniqueness

`admin_create_user` (backend/src/application/auth.rs:183) checks the username,
then inserts. The `identities.username` unique constraint catches the race, but
the violation surfaces as a `Database(...)` 500 instead of a clean
`UsernameTaken` 409.

Mitigation if ever needed: catch the unique-violation and map to
`UsernameTaken`.

### Non-atomic reads of food logs

`PostgresFoodLogRepository::find_by_id` / `find_by_user_and_range`
(backend/src/infrastructure/postgres/food_log.rs:109, 130) fetch the log header
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
`staging_*.raw_payload` is hardcoded to `None` in `interfaces/http/import.rs`,
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

`CatalogError`, `FoodLogError`, `MealError`, `AuthError`, and `ImportError` each
have a `Database(#[from] sqlx::Error)` variant
(`backend/src/domain/catalog.rs:531`, `domain/food_log.rs:249`,
`domain/meal.rs:289`, `domain/auth.rs:136`, `domain/import.rs:131`). The domain
layer is the inner ring and should not depend on the DB driver — right now
`domain/` cannot compile without sqlx, and every consumer of a domain error
transitively pulls it in.

Mitigation if ever needed: define an opaque `RepositoryError` (or per-trait
error) in domain, and have the postgres adapters map `sqlx::Error` into it
before returning.

### Repository traits carry HTTP/query-layer shapes

`ProductRepository::search` takes a
`ProductSearchQuery { text, include_categories: Vec<String>, exclude_categories: Vec<String> }`
(`backend/src/domain/catalog.rs:10`), and `SummaryRepository::get_summary`
returns a `Vec<SummaryEntry>` shaped for the HTTP response. The repository port
should express domain intent, not transport a request DTO with raw strings.
Changing the HTTP API currently forces a domain edit.

Mitigation if ever needed: introduce a domain-level search specification (e.g.
`ProductSearchSpec` with typed `Category` filters) and return domain
projections, then translate at the adapter boundary.

### Primitive-obsessed quantity and nutrition values

`Quantity { amount: Decimal, unit: UnitCode }`
(`backend/src/domain/nutrition.rs:5`) and `ProductNutrient::amount_per_100g`
have no smart constructor — the `amount > 0` check only runs inside
`Product::quantity_to_grams` / `Meal::quantity_to_grams`
(`backend/src/domain/catalog.rs`, `backend/src/domain/meal.rs`). An ill-formed
`Quantity` is constructible anywhere in the crate.

Mitigation if ever needed: make `Quantity::new(...) -> Result<Self, _>` the only
way to build one, and reject non-positive amounts at construction. Same pattern
for `AmountPer100g` (today the validator is a free function on the type, not a
constructor).

### FoodLog still reaches across aggregates

`application/food_log.rs` imports `domain::catalog::*` and
`domain::meal::{Meal, MealComponentItem, MealId}`, then calls
`product.nutrition_for(...)` / `meal.nutrition_for(...)` (and uses
`MealComponentItem` in `load_meal_products`). The calculation is now on the
aggregates rather than free functions, but Food Log still directly depends on
Meal and Product to compute its own state. The three look like separate bounded
contexts but are tightly coupled.

Mitigation if ever needed: introduce a domain port that answers "what nutrition
does this referenced item contribute?", and have FoodLog depend on that instead
of importing sibling aggregate internals.

### Meal aggregate creation has no transaction boundary

`application/meal.rs:68-82` resolves `MealComponent`s by awaiting per-product lookups,
then calls `meal_repo.create(&meal)`. Product existence is checked outside any
transaction, and there's no compensation if a later lookup fails mid-way.
Aggregates exist to define a consistency boundary; here it's implicit.

Mitigation if ever needed: wrap component resolution + meal insert in a single
transactional unit of work, or validate all referenced products in one batched
query before constructing the aggregate.

### Invariant parsing happens in the application layer

`application/food_log.rs` calls `MealSlot::from_str(s)` and maps the error
to `FoodLogError::Validation`. Parsing untrusted strings at the boundary is
fine, but the application layer also owns the error mapping and reshaping.
`MealComponentItem::parse` is similarly called from `application/meal.rs:175`.

Mitigation if ever needed: have HTTP DTOs parse into domain types at the edge
(via `TryFrom`), so the application service only ever sees already-validated
domain values.

## Application layer

The application layer earns its keep on the write paths (auth flows,
log_food/log_meal, create_meal, custom-food create/update, import staging) —
anything that orchestrates multiple repos or assembles a domain aggregate from
looked-up dependencies. The items below are about the parts that don't, plus
inconsistencies in how the layer is shaped.

### Passthroughs moved into HTTP handlers

The old catalog service passthroughs are gone; catalog handlers now call
`product_repo`, `nutrient_repo`, and `unit_repo` directly
(`interfaces/http/catalog.rs:223-465`). The same mixed boundary still exists in
other places: `summary_handler` calls `summary_repo.get_summary(...)` directly
(`interfaces/http/food_log.rs:257-276`), import error lookup calls
`import_repo.get_errors(...)` directly, and meal list/detail are handled
outside `MealServices`.

Mitigation if ever needed: make this an explicit convention. Either handlers may
call repos for read-only passthroughs, or every use case goes through a service.

### Cross-layer leakage in `food_log`

- `impl FoodLog { fn item_id(&self) -> Uuid }` is defined in
  `application/food_log.rs:289-293` — a method on a domain type, declared in the
  application layer.
- `log_item_id` / `log_item_type` (`application/food_log.rs:275-287`)
  pattern-match on `LoggedItem`; both belong as methods on the domain enum.
- `From<domain::meal::MealError> for FoodLogError`
  (`application/food_log.rs:12-22`) is a conversion between two domain errors,
  declared in application.

Mitigation if ever needed: move all three into `domain/food_log.rs`.

### Duplicate / near-duplicate logic

- `load_meal_products` exists twice — `application/food_log.rs:251` returning
  `FoodLogError`, and `MealServices::load_meal_products`
  (`application/meal.rs:187`) returning `MealError`. Same loop over
  `meal.components`.
- `log_food` and `log_meal` (`application/food_log.rs:72-139`) share ~90% of
  their structure (`MealSlot` parse, quantity build, repo write); they diverge
  only at the item-resolution step.
- `ImportServices::stage_foods` / `stage_nutrients` / `stage_servings`
  (`application/import.rs:33-200`) are three ~50-line methods that vary only in
  the per-row validation predicate.

Mitigation if ever needed: a shared helper on `Meal` (or in domain) for product
loading; a private `resolve_item` helper inside `FoodLogServices`; a generic
`stage<T>(...)` parameterized by a validator closure for the import staging
trio.

### Domain validation living in application

`ImportServices::stage_*` per-row validation (`source.is_empty()`,
`nutrient_code.is_empty()`, `quantity <= 0`, `grams <= 0`) is invariant-checking
on staged rows. The staged types (`StagedImportProduct`, `StagedImportNutrient`,
`StagedImportServing`) own those invariants — application should be collecting
`Ok`/`Err` from a domain constructor, not running the checks itself. This
overlaps with the existing "Invariant parsing happens in the application layer"
item.

Mitigation if ever needed: `StagedImportProduct::try_new(...)` / equivalents on
each staged type, returning a domain error the service maps once.

### Inconsistent `Clone` impls

`ImportServices` (`application/import.rs:9-15`) hand-writes `Clone`.
`MealServices` and `FoodLogServices` use `#[derive(Clone)]`. `Arc<dyn Trait>` is
`Clone`, so the derive form works here too. The previous `CatalogServices`
example is gone with the deleted catalog service.

Mitigation if ever needed: replace the hand impls with `#[derive(Clone)]`.

### Vestigial / undocumented

- `get_session` (`application/auth.rs:141`) silently discards `update_last_seen`
  errors via `let _ = ...`. Almost certainly intentional (best-effort heartbeat
  refresh) but undocumented.
- `ImportServices::commit_job` (`application/import.rs:191-211`) requires
  `food_count > 0` to commit, but doesn't gate on nutrient or serving counts.
  Either intentional (foods are the primary entity) and worth a comment, or a
  bug.
- `UpdateFoodInput` / `UpdateMealInput` use `Option<Option<T>>` for PATCH-style
  "absent vs explicit-null vs value" with no doc explaining the convention.

Mitigation if ever needed: one-line comments on the silent-discard and the
commit asymmetry; either a `Patch<T>` enum or a doc comment on the PATCH input
structs.

### Mock-by-singleton test smell

`MockProductLookup::with_product(p)` (and `MockMealProductLookup`) returns the
same product for _any_ `ProductId`. Tests work around this by hardcoding
`Uuid::nil()` everywhere they create or look up a product. The mock isn't
actually testing the lookup path — it's testing "service called the lookup."

Mitigation if ever needed: replace with a `HashMap<ProductId, Product>`-backed
mock so tests describe the data they expect to find.

## Backend cleanup

### HTTP enum string conversions are still manual

After domain enum string conversion is moved to `strum`, the HTTP DTO layer can
still be simplified. Several handlers currently map enum-like values into
strings by hand, for example role/status/source/visibility fields.

Mitigation if ever needed: use serde enum renaming on DTO-facing enums where the
API value is stable, such as `#[serde(rename_all = "snake_case")]` or
per-variant `#[serde(rename = "...")]`. This should reduce repeated
`as_str().to_string()` conversions at the HTTP boundary.

### Error response shapes are duplicated per HTTP module

Several HTTP modules define their own `ErrorResponse`, `ErrorBody`, and
status/code mapping helpers. The response shape is mostly the same, but each
module owns a local copy.

Mitigation if ever needed: introduce a shared HTTP `ApiError` / `ErrorResponse`
type that implements `IntoResponse`, then implement `From<CatalogError>`,
`From<FoodLogError>`, `From<MealError>`, etc. for it. Keep module-specific
mappings only where the public API behavior genuinely differs.

### General-purpose errors should stay at the outer edge

Application/domain errors are structured because handlers need to distinguish
validation, not-found, forbidden, and internal failures. Replacing those with
`anyhow::Error` would make HTTP mapping and tests less explicit.

Mitigation if ever needed: use `anyhow` only for outer glue code such as
startup/config/server wiring or CLI-style import tools, where callers only need
contextual failure reporting and do not branch on concrete error variants.
