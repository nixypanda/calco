# Backend Next/Later Design Plan

## Summary

This document captures backend design implications for non-MVP features before implementation. The goal is to avoid choices in the MVP backend that would force unnecessary redesign later.

Current sections:

- Next: Meals and recipes
- Next: Imports

Planned later sections:

- Later: Offline support, barcode scanning, admin, and multi-user support

## Next: Meals And Recipes

Meals and recipes make foods composable. A meal is a reusable user-owned aggregate made from one or more components.

### Domain Concepts

| Concept | Type | Why |
|---|---|---|
| `Meal` | Aggregate root entity | Reusable user-defined recipe/meal with identity and lifecycle. |
| `MealComponent` | Child value object | Owned by `Meal`; represents one ingredient/component. |
| `MealId` | Value object | Identifier for a meal. |
| `MealName` | Value object | Validated meal name. |
| `MealNotes` | Value object | Optional notes/description. |
| `MealYield` | Value object | Total output quantity, such as `1000g` or `4 servings`. |
| `MealComponentItem` | Value object enum | Identifies the component item: product initially, meal later if nested meals are allowed. |
| `MealNutrition` | Calculated value object | Calculated nutrient totals for a meal. |
| `MealNutritionCalculator` | Domain service | Calculates nutrition from meal components. |
| `MealCyclePolicy` | Domain service/policy | Prevents recursive meal definitions if nested meals are allowed. |

### Meal Aggregate

```text
Meal aggregate
  Meal entity, aggregate root
  MealComponent child value object
```

`Meal` is an entity because it has identity and lifecycle. Users create, edit, delete, list, and log meals.

`MealComponent` is a child value object because it has no independent lifecycle. It exists only as part of a `Meal` and is replaced through the `Meal` aggregate.

Recommended initial shape:

```text
Meal
  id: MealId
  user_id: UserId
  name: MealName
  notes: Option<MealNotes>
  total_quantity: Option<Quantity>
  components: Vec<MealComponent>
  created_at
  updated_at

MealComponent
  item: MealComponentItem
  quantity: Quantity

MealComponentItem
  Product(ProductId)
  Meal(MealId) later
```

For the first meals implementation, prefer product-only components:

```text
MealComponentItem
  Product(ProductId)
```

Nested meals can be added later by enabling `Meal(MealId)` and adding cycle validation.

### Domain Rules

- A meal belongs to one user.
- Meal components are changed through the `Meal` aggregate.
- A meal must have at least one component before it can be logged.
- A meal component must reference exactly one item.
- Product-only meal components do not require cycle validation.
- Nested meals require cycle validation before saving.
- Meal nutrition is calculated from component nutrition and is not stored as canonical historical data.
- Food logs still snapshot calculated nutrients at log time, regardless of whether the logged item is a product or meal.

### Database Mapping

```text
Meal aggregate
  meals
  meal_components
```

#### `meals`

Stores the `Meal` aggregate root.

```text
id                  -> MealId
user_id             -> UserId
name                -> MealName
notes               -> Option<MealNotes>
total_quantity      -> Option<Quantity.amount>
total_unit          -> Option<Quantity.unit>
created_at
updated_at
```

#### `meal_components`

Stores `MealComponent` child value objects owned by `Meal`.

```text
id                  -> persistence id only in v1
meal_id             -> MealId
component_product_id -> MealComponentItem::Product(ProductId)
component_meal_id   -> MealComponentItem::Meal(MealId), later
quantity            -> Quantity.amount
unit                -> Quantity.unit
created_at
```

Domain meaning:

- `meal_components.id` is for persistence and UI convenience.
- Components are not independent aggregate roots.
- Components should not be mutated independently from the parent `Meal`.

Database constraint:

```text
Exactly one of component_product_id or component_meal_id is set.
```

### Existing MVP Design Impact

The MVP backend should model logged items as an enum from the start:

```text
LoggedItem
  Product(ProductId)
  Meal(MealId) later
```

The MVP database can include both columns even if meal logging is disabled initially:

```text
food_logs.item_product_id
food_logs.item_meal_id
```

The invariant remains:

```text
Exactly one logged item reference is set.
```

For MVP, application validation should allow only product logs. When meals are implemented, the same `FoodLog` aggregate can accept `LoggedItem::Meal`.

The nutrition calculation boundary should also be designed as item-based:

```text
calculate_logged_item(item, quantity)
calculate_product(product_id, quantity)
calculate_meal(meal_id, quantity) later
```

This prevents the logging flow from becoming product-specific.

### API Mapping

Meal APIs should expose the `Meal` aggregate, not independent component resources.

```text
POST   /meals
GET    /meals
GET    /meals/{id}
PUT    /meals/{id}
DELETE /meals/{id}
GET    /meals/{id}/nutrients?quantity=250&unit=g
```

Avoid initially:

```text
POST   /meals/{id}/components
PUT    /meals/{id}/components/{component_id}
DELETE /meals/{id}/components/{component_id}
```

Those expose child value objects as independent resources. Prefer aggregate-shaped create/update requests.

#### `POST /meals`

Request shape:

```json
{
  "name": "Paneer rice bowl",
  "notes": "Lunch meal prep",
  "total_quantity": {
    "amount": 1,
    "unit": "serving"
  },
  "components": [
    {
      "item": { "type": "product", "id": "rice-product-id" },
      "quantity": { "amount": 150, "unit": "g" }
    },
    {
      "item": { "type": "product", "id": "paneer-product-id" },
      "quantity": { "amount": 100, "unit": "g" }
    }
  ]
}
```

Behavior:

- Create one `meals` row.
- Create owned `meal_components` rows.
- Commit all changes atomically.

#### `PUT /meals/{id}`

Request shape should match `POST /meals`.

Behavior:

- Update the meal root fields.
- Replace owned components through the `Meal` aggregate.
- Do not mutate historical food log snapshots.

#### `GET /meals/{id}/nutrients?quantity=250&unit=g`

Behavior:

- Load the `Meal` aggregate.
- Load referenced product aggregates.
- Calculate nutrition for each component.
- Sum component nutrition.
- Scale to the requested quantity.
- Return calculated nutrient totals.

Response shape:

```json
{
  "meal_id": "meal-uuid",
  "quantity": {
    "amount": 250,
    "unit": "g"
  },
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount": 530, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount": 28, "unit": "g" }
  ]
}
```

### Food Log Extension

When meals are implemented, `POST /logs` can accept:

```json
{
  "logged_at": "2026-05-29T13:30:00+05:30",
  "meal_slot": "lunch",
  "item": {
    "type": "meal",
    "id": "meal-uuid"
  },
  "quantity": {
    "amount": 1,
    "unit": "serving"
  },
  "notes": "Lunch"
}
```

Behavior remains unchanged at the logging boundary:

- Load the logged item.
- Calculate nutrition.
- Create `FoodLog`.
- Create owned `FoodLogNutrientSnapshot` rows.
- Historical snapshots remain stable if the meal recipe changes later.

### Test Plan

Domain tests:

- Meal must have a name.
- Meal component must reference exactly one item.
- Product-only meal nutrition sums component product nutrition.
- Nested meal cycle policy rejects recursive definitions once nested meals are enabled.

Application tests:

- Meal creation writes meal and components atomically.
- Meal update replaces owned components.
- Meal nutrition calculation scales to requested quantity.
- Logging a meal creates food log snapshots.
- Editing a meal does not change historical food log snapshots.

Infrastructure tests:

- `meals` and `meal_components` migrations apply cleanly.
- Repositories reconstruct `Meal` aggregates from normalized tables.
- Component replacement deletes removed rows and inserts current rows atomically.

Interface tests:

- Meal create/update routes accept aggregate-shaped payloads.
- Component mutation routes are not exposed.
- Meal log request works through the existing `/logs` route once enabled.

## Next: Imports

Imports should be isolated from the core Catalog and Logging models. The import module owns staging, validation, errors, and job lifecycle. Once data is ready to commit, it writes to Catalog through Catalog-facing application interfaces instead of bypassing core rules.

Import is an anti-corruption/staging layer around external food datasets.

### Domain Concepts

| Concept | Type | Why |
|---|---|---|
| `ImportJob` | Aggregate root entity | Represents one controlled import run with identity, source, status, timestamps, and lifecycle. |
| `StagedImportProduct` | Child value object/record | Validated product row waiting to be committed; owned by an import job. |
| `StagedImportNutrient` | Child value object/record | Validated nutrient row waiting to be committed; owned by an import job. |
| `ImportError` | Child record | Row-level validation or commit issue owned by an import job. |
| `ImportId` | Value object | Identifier for an import job. |
| `ImportSource` | Value object | Source such as `OFF`, `USDA`, `IFCT`, or `CUSTOM_JSONL`. |
| `ImportStatus` | Value object enum | Controlled status such as `pending`, `running`, `committed`, `failed`, or `cancelled`. |
| `ImportRowNumber` | Value object | Source row number for diagnostics. |
| `ImportRawPayload` | Value object | Original JSON row for debugging and audit. |
| `ImportBatchResult` | Value object | Accepted/rejected counts for batch responses. |
| `ImportValidator` | Domain service | Validates import rows against import and catalog rules. |
| `ImportCommitPolicy` | Domain service/policy | Controls status transitions and commit preconditions. |
| `SourceNutrientMapping` | Reference concept | Maps source-specific nutrient names/codes to canonical `NutrientCode` when source-specific importers are added. |

### Import Aggregate

```text
ImportJob aggregate
  ImportJob entity, aggregate root
  StagedImportProduct child record/value object
  StagedImportNutrient child record/value object
  ImportError child record
```

`ImportJob` is an entity because it has identity and lifecycle. It moves through staging, validation, commit, failure, and inspection.

Staged rows and errors are owned by the import job. They are not Catalog entities. They become Catalog data only after commit succeeds.

Recommended shape:

```text
ImportJob
  id: ImportId
  source: ImportSource
  status: ImportStatus
  created_by: Option<UserId>
  created_at
  committed_at: Option<DateTime>
  failed_at: Option<DateTime>

StagedImportProduct
  source: ImportSource
  source_id: SourceProductId
  barcode: Option<Barcode>
  name: ProductName
  brand: Option<Brand>
  category: Option<Category>
  serving_size_g: Option<Grams>
  raw_payload: ImportRawPayload
  row_number: Option<ImportRowNumber>

StagedImportNutrient
  source: ImportSource
  source_id: SourceProductId
  nutrient_code: NutrientCode
  amount_per_100g: AmountPer100g
  raw_payload: ImportRawPayload
  row_number: Option<ImportRowNumber>

ImportError
  row_number: Option<ImportRowNumber>
  error: ImportErrorMessage
  raw_payload: Option<ImportRawPayload>
```

### Domain Rules

- Import scripts must not write directly to PostgreSQL.
- Import jobs move through explicit statuses.
- Import rows are staged before they become catalog data.
- Food rows require `source`, `source_id`, and `name`.
- Nutrient rows require `source`, `source_id`, `nutrient_code`, and `amount_per_100g`.
- Nutrient codes must resolve to canonical `NutrientCode` values.
- Invalid rows produce row-level `ImportError` records with the original payload preserved.
- A committed staged product becomes a normal `Product` aggregate.
- A committed staged nutrient becomes a `ProductNutrient` child value object owned by the target `Product`.
- Imports must respect Catalog invariants, including `(source, source_id)` identity and valid nutrient values.

### Database Mapping

```text
ImportJob aggregate
  imports
  import_errors
  staging_products
  staging_product_nutrients
```

#### `imports`

Stores the `ImportJob` aggregate root.

```text
id                  -> ImportId
source              -> ImportSource
status              -> ImportStatus
created_by          -> Option<UserId>
created_at
committed_at
failed_at
```

#### `import_errors`

Stores import-owned validation and commit errors.

```text
id                  -> persistence id
import_id           -> ImportId
row_number          -> Option<ImportRowNumber>
error               -> ImportErrorMessage
raw_payload         -> Option<ImportRawPayload>
created_at
```

#### `staging_products`

Stores staged product rows before Catalog commit.

```text
import_id           -> ImportId
source              -> ImportSource
source_id           -> SourceProductId
barcode             -> Option<Barcode>
name                -> ProductName
brand               -> Option<Brand>
category            -> Option<Category>
serving_size_g      -> Option<Grams>
raw_payload         -> ImportRawPayload
row_number          -> Option<ImportRowNumber>
```

#### `staging_product_nutrients`

Stores staged product nutrient rows before Catalog commit.

```text
import_id           -> ImportId
source              -> ImportSource
source_id           -> SourceProductId
nutrient_code       -> NutrientCode
amount_per_100g     -> AmountPer100g
raw_payload         -> ImportRawPayload
row_number          -> Option<ImportRowNumber>
```

### Catalog Integration

Imports should commit through Catalog-facing application operations.

Conceptually:

```text
StagedImportProduct
  -> UpsertCatalogProduct command
  -> Product aggregate

StagedImportNutrient
  -> Replace/upsert Product.nutrients
  -> ProductNutrient child value object
```

The import module may batch these operations for performance, but the behavior must remain equivalent to using Catalog rules:

- Imported products are identified by `(source, source_id)`.
- Imported products are global catalog products by default.
- Product nutrients stay owned by `Product`.
- Historical `FoodLogNutrientSnapshot` rows are never recalculated during import.

### Existing MVP Design Impact

The MVP Catalog model should keep these fields even before imports exist:

```text
Product.source
Product.source_id
Product.visibility
ProductNutrient.source
ProductNutrient.confidence
```

The MVP database should keep:

```text
UNIQUE (source, source_id)
```

`NutrientCode` should be stable and canonical from the start because imports rely on it for validation and mapping.

### API Mapping

Import APIs expose the import job workflow.

```text
POST /imports
POST /imports/{id}/foods
POST /imports/{id}/nutrients
POST /imports/{id}/commit
GET  /imports/{id}
GET  /imports/{id}/errors
```

#### `POST /imports`

Request shape:

```json
{
  "source": "OFF"
}
```

Response shape:

```json
{
  "id": "import-uuid",
  "source": "OFF",
  "status": "pending"
}
```

#### `POST /imports/{id}/foods`

Request shape:

```json
{
  "rows": [
    {
      "row_number": 1,
      "source": "OFF",
      "source_id": "8901234567890",
      "barcode": "8901234567890",
      "name": "Amul Paneer",
      "brand": "Amul",
      "category": "Dairy",
      "serving_size_g": 100
    }
  ]
}
```

Response shape:

```json
{
  "accepted": 1,
  "rejected": 0
}
```

#### `POST /imports/{id}/nutrients`

Request shape:

```json
{
  "rows": [
    {
      "row_number": 1,
      "source": "OFF",
      "source_id": "8901234567890",
      "nutrient_code": "PROTEIN_G",
      "amount_per_100g": 18.3
    }
  ]
}
```

Response shape:

```json
{
  "accepted": 1,
  "rejected": 0
}
```

#### `POST /imports/{id}/commit`

Behavior:

- Validate that the import can commit.
- Upsert products by `(source, source_id)`.
- Upsert or replace product nutrients.
- Mark the import as `committed`.
- If commit fails, mark the import as `failed` and record an import error.

#### `GET /imports/{id}`

Response shape:

```json
{
  "id": "import-uuid",
  "source": "OFF",
  "status": "committed",
  "created_at": "2026-05-29T18:00:00Z",
  "committed_at": "2026-05-29T18:05:00Z"
}
```

#### `GET /imports/{id}/errors`

Response shape:

```json
{
  "items": [
    {
      "row_number": 12,
      "error": "Unknown nutrient code: UNKNOWN_X",
      "raw_payload": {
        "source": "OFF",
        "source_id": "8901234567890",
        "nutrient_code": "UNKNOWN_X",
        "amount_per_100g": 1
      }
    }
  ]
}
```

### Dataset-Specific Adapters

The first import API should accept generic normalized rows. Dataset-specific adapters should be separate modules or scripts that convert external data into this generic format.

Initial:

- Generic JSONL reader/parser.

Later:

- Open Food Facts adapter.
- USDA adapter.
- IFCT adapter.

Adapters should not write to Catalog tables directly. They call import APIs or import application services.

### Test Plan

Domain tests:

- Import status transitions.
- Food row validation.
- Nutrient row validation.
- Unknown nutrient code rejection.
- Commit policy rejects invalid statuses.

Application tests:

- Create import job.
- Stage valid food rows.
- Stage invalid rows as import errors.
- Stage nutrient rows only when nutrient codes are canonical.
- Commit import upserts Catalog products.
- Commit import writes Product-owned nutrients.
- Reimport updates existing `(source, source_id)` products.

Infrastructure tests:

- Import migrations apply cleanly.
- Staging rows and errors are persisted.
- Commit transaction updates Catalog tables atomically.
- Failed commit records an import error.

Interface tests:

- Batch endpoints enforce size limits.
- Valid rows return accepted counts.
- Invalid rows return rejected counts and are visible through `/errors`.
- Import routes are admin-only once auth roles exist.

## Later: Nutrition Goals

Nutrition goals are the only currently identified Later / More Features item that needs a meaningful new domain concept.

Other later features are handled elsewhere:

- Barcode scanning is an interface feature that feeds `Barcode` into existing food search.
- Offline cache is a frontend/infrastructure concern.
- Expanded nutrient storage is already supported by the long-form nutrient model.
- Direct food corrections use admin Catalog update flows.
- Export jobs are an isolated job component that can use public application interfaces.
- Backup/restore is operational.
- Auth is a separate design document.

### Domain Concepts

| Concept | Type | Why |
|---|---|---|
| `NutritionGoal` | Aggregate root entity | User-owned goal profile with identity, lifecycle, active dates, and targets. |
| `GoalTarget` | Child value object | One nutrient target owned by a `NutritionGoal`. |
| `NutritionGoalId` | Value object | Identifier for a goal. |
| `GoalName` | Value object | User-visible goal name. |
| `GoalPeriod` | Value object enum | Period the goal applies to, initially daily or weekly. |
| `Target` | Value object enum | Encodes minimum, maximum, range, or exact target semantics. |
| `GoalProgress` | Calculated value object/read model | Compares actual summary values to goal targets. |
| `GoalProgressStatus` | Value object enum | Result status such as below minimum, within range, above maximum, met, or not met. |
| `GoalProgressCalculator` | Domain service | Compares summaries against goals. |

### NutritionGoal Aggregate

```text
NutritionGoal aggregate
  NutritionGoal entity, aggregate root
  GoalTarget child value object
```

`NutritionGoal` is an entity because users create, activate, edit, replace, and delete goals over time.

`GoalTarget` is a child value object because it has no independent lifecycle. Targets are replaced through the parent goal.

Rust domain shape should use enums. Repository implementations are responsible for translating these enums to and from database tables.

```rust
pub struct NutritionGoal {
    pub id: NutritionGoalId,
    pub user_id: UserId,
    pub name: GoalName,
    pub period: GoalPeriod,
    pub targets: Vec<GoalTarget>,
    pub active_from: NaiveDate,
    pub active_until: Option<NaiveDate>,
}

pub struct GoalTarget {
    pub nutrient_code: NutrientCode,
    pub target: Target,
}

pub enum GoalPeriod {
    Daily,
    Weekly,
}

pub enum Target {
    Minimum {
        amount: Decimal,
        unit: UnitCode,
    },
    Maximum {
        amount: Decimal,
        unit: UnitCode,
    },
    Range {
        min: Decimal,
        max: Decimal,
        unit: UnitCode,
    },
    Exact {
        amount: Decimal,
        unit: UnitCode,
    },
}
```

Example:

```rust
NutritionGoal {
    id: goal_id,
    user_id,
    name: GoalName::new("Cutting"),
    period: GoalPeriod::Daily,
    active_from,
    active_until: None,
    targets: vec![
        GoalTarget {
            nutrient_code: NutrientCode::new("ENERGY_KCAL"),
            target: Target::Maximum {
                amount: dec!(2100),
                unit: UnitCode::new("kcal"),
            },
        },
        GoalTarget {
            nutrient_code: NutrientCode::new("PROTEIN_G"),
            target: Target::Minimum {
                amount: dec!(150),
                unit: UnitCode::new("g"),
            },
        },
    ],
}
```

### Domain Rules

- A goal belongs to one user.
- A goal has one period.
- A goal has one or more targets.
- Each target references a canonical `NutrientCode`.
- Targets are changed through the `NutritionGoal` aggregate.
- Active date ranges should not overlap for goals that are intended to be mutually exclusive. If multiple simultaneous goals are allowed later, the API should make that explicit.
- Goal progress is calculated from summaries and goals; it does not need to be stored initially.

### Database Mapping

```text
NutritionGoal aggregate
  nutrition_goals
  nutrition_goal_targets
```

#### `nutrition_goals`

Stores the `NutritionGoal` aggregate root.

```text
id                  -> NutritionGoalId
user_id             -> UserId
name                -> GoalName
period              -> GoalPeriod
active_from
active_until
created_at
updated_at
```

#### `nutrition_goal_targets`

Stores `GoalTarget` child value objects owned by `NutritionGoal`.

```text
goal_id             -> NutritionGoalId
nutrient_id         -> NutrientId, resolved from NutrientCode
target_kind         -> Target enum discriminator
amount              -> used by minimum, maximum, exact
min_amount          -> used by range
max_amount          -> used by range
unit                -> UnitCode
```

Repository mapping examples:

```text
Target::Minimum { amount: 150, unit: g }
  -> target_kind = minimum
  -> amount = 150
  -> min_amount = null
  -> max_amount = null
  -> unit = g

Target::Range { min: 50, max: 80, unit: g }
  -> target_kind = range
  -> amount = null
  -> min_amount = 50
  -> max_amount = 80
  -> unit = g
```

Prefer relational columns over JSONB because goals will be queried and reported.

### Goal Progress

Goal progress is calculated from summaries.

Input:

```text
NutritionGoal
DailySummary or RangeSummary
```

Output:

```rust
pub struct GoalProgress {
    pub nutrient_code: NutrientCode,
    pub actual_amount: Decimal,
    pub actual_unit: UnitCode,
    pub target: Target,
    pub status: GoalProgressStatus,
}

pub enum GoalProgressStatus {
    BelowMinimum,
    WithinRange,
    AboveMaximum,
    Met,
    NotMet,
}
```

`GoalProgress` is calculated/read-model data. It should not be stored in the initial goals implementation.

### API Mapping

Goal APIs expose the `NutritionGoal` aggregate and goal-progress read models.

```text
POST   /goals
GET    /goals
GET    /goals/active?date=2026-05-29
GET    /goals/{id}
PUT    /goals/{id}
DELETE /goals/{id}
GET    /goals/progress?date=2026-05-29
```

#### `POST /goals`

Request shape uses tagged JSON that maps cleanly to Rust enums:

```json
{
  "name": "Cutting",
  "period": "daily",
  "active_from": "2026-05-29",
  "active_until": null,
  "targets": [
    {
      "nutrient_code": "ENERGY_KCAL",
      "target": {
        "type": "maximum",
        "amount": 2100,
        "unit": "kcal"
      }
    },
    {
      "nutrient_code": "PROTEIN_G",
      "target": {
        "type": "minimum",
        "amount": 150,
        "unit": "g"
      }
    },
    {
      "nutrient_code": "FAT_G",
      "target": {
        "type": "range",
        "min": 50,
        "max": 80,
        "unit": "g"
      }
    }
  ]
}
```

Behavior:

- Validate canonical nutrient codes.
- Validate target units match canonical nutrient units or are explicitly convertible.
- Create `NutritionGoal`.
- Create owned `GoalTarget` rows.
- Commit atomically.

#### `PUT /goals/{id}`

Request shape should match `POST /goals`.

Behavior:

- Update goal root fields.
- Replace owned targets through the `NutritionGoal` aggregate.
- Commit atomically.

#### `GET /goals/progress?date=2026-05-29`

Response shape:

```json
{
  "date": "2026-05-29",
  "goal": {
    "id": "goal-uuid",
    "name": "Cutting",
    "period": "daily"
  },
  "progress": [
    {
      "nutrient_code": "ENERGY_KCAL",
      "actual": { "amount": 1980, "unit": "kcal" },
      "target": { "type": "maximum", "amount": 2100, "unit": "kcal" },
      "status": "met"
    },
    {
      "nutrient_code": "PROTEIN_G",
      "actual": { "amount": 132, "unit": "g" },
      "target": { "type": "minimum", "amount": 150, "unit": "g" },
      "status": "below_minimum"
    }
  ]
}
```

### Existing MVP Design Impact

The MVP summary API should return totals by nutrient code, not hardcoded macro fields, so goals can compare against any nutrient later.

Good:

```json
{
  "totals": [
    { "code": "ENERGY_KCAL", "amount": 2100, "unit": "kcal" },
    { "code": "PROTEIN_G", "amount": 145, "unit": "g" }
  ]
}
```

Avoid:

```json
{
  "calories": 2100,
  "protein_g": 145
}
```

### Test Plan

Domain tests:

- Goal must have at least one target.
- Target nutrient code must be canonical.
- Range target requires `min <= max`.
- Goal progress status is correct for minimum, maximum, range, and exact targets.

Application tests:

- Goal creation writes goal and targets atomically.
- Goal update replaces owned targets.
- Active goal lookup respects date range.
- Goal progress uses summary values by nutrient code.

Infrastructure tests:

- Goal migrations apply cleanly.
- Repository maps relational target rows to Rust `Target` enum variants.
- Repository maps Rust `Target` enum variants to relational target rows.

Interface tests:

- Tagged JSON target payloads decode correctly.
- Invalid target payloads return stable validation errors.
- Summary goal-progress response preserves target enum shape.

## Later: Direct Catalog Corrections

Direct corrections are admin edits to imported/global catalog foods. User-owned custom foods are already handled by `PUT /foods/custom/{id}`.

No new core domain concept is required if corrections are immediate edits. The existing `Product` aggregate owns the editable product fields, nutrients, and servings.

### API Mapping

Admin-only correction APIs:

```text
PUT /admin/foods/{id}
```

Request shape should mirror custom food update:

```json
{
  "name": "Corrected Paneer",
  "brand": "Amul",
  "category": "Dairy",
  "serving_size_g": 100,
  "default_quantity": 100,
  "default_unit": "g",
  "nutrients": [
    { "code": "ENERGY_KCAL", "amount_per_100g": 296 },
    { "code": "PROTEIN_G", "amount_per_100g": 18.3 }
  ],
  "servings": [
    { "label": "1 cube", "quantity": 1, "unit": "piece", "grams": 25 }
  ]
}
```

Behavior:

- Require admin authorization.
- Load the target `Product` aggregate.
- Update product fields.
- Replace owned nutrients and servings through the `Product` aggregate.
- Do not mutate historical `FoodLogNutrientSnapshot` rows.
- Prefer recording an audit entry when admin audit logging exists.

Avoid public mutation endpoints for child resources:

```text
PUT /admin/product-nutrients/{id}
PUT /admin/product-servings/{id}
```

Those would expose child value objects as independent resources.

## Later: Export Jobs

Exports are an isolated job component. They should read through public application/query interfaces and should not own or mutate core nutrition data.

### Domain Concepts

| Concept | Type | Why |
|---|---|---|
| `ExportJob` | Aggregate root entity | Represents one async export request with identity, status, format, timestamps, and lifecycle. |
| `ExportFormat` | Value object enum | Export format such as JSON or CSV. |
| `ExportScope` | Value object enum | Defines what data is exported, such as logs, custom foods, or full user data. |
| `ExportStatus` | Value object enum | Controlled status such as pending, running, completed, failed, or expired. |

### Domain Rules

- An export belongs to one user.
- Export jobs read existing data; they do not modify food logs, products, meals, goals, or summaries.
- Generated export files should expire.
- Export jobs should not expose another user's data.

### Database Mapping

```text
export_jobs
  id
  user_id
  format
  scope
  status
  file_path or object_key
  error
  created_at
  completed_at
  expires_at
```

### API Mapping

```text
POST /exports
GET  /exports/{id}
GET  /exports/{id}/download
```

`POST /exports` request:

```json
{
  "format": "json",
  "scope": "full_user_data"
}
```

Implementation note:

- The export worker can call application query services such as `GetLogs`, `GetSummary`, and catalog/profile queries.
- It should not query private tables directly unless it is implemented inside the infrastructure layer behind an application export service.

## Later: Reports And Analytics

Reports are read models derived from logged nutrient snapshots and, later, goals. They should not introduce new write-side domain concepts initially.

### Report Types

- Daily nutrient totals.
- Date-range nutrient totals.
- Nutrient trend series.
- Calorie and macro charts.
- Goal progress over time once goals exist.

### API Mapping

Keep reports nutrient-code based.

Existing flexible summary endpoint:

```text
GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=ENERGY_KCAL,PROTEIN_G
```

Add time-series reports only when chart needs require them:

```text
GET /reports/nutrients/timeseries?from=YYYY-MM-DD&to=YYYY-MM-DD&interval=day&codes=ENERGY_KCAL,PROTEIN_G
GET /reports/goals/progress?from=YYYY-MM-DD&to=YYYY-MM-DD
```

Time-series response shape:

```json
{
  "from": "2026-05-01",
  "to": "2026-05-29",
  "interval": "day",
  "series": [
    {
      "code": "ENERGY_KCAL",
      "unit": "kcal",
      "points": [
        { "date": "2026-05-01", "amount": 2100 },
        { "date": "2026-05-02", "amount": 1980 }
      ]
    }
  ]
}
```

### Existing MVP Design Impact

- Store food log snapshots long-form.
- Keep summaries nutrient-code based.
- Avoid hardcoded calorie/macro-only response models in backend APIs.
- Add report-specific caches later only if direct aggregation is too slow.
