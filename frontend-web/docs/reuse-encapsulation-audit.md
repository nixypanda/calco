# Frontend Reuse Encapsulation Audit

This audit lists the main places where the current Elm frontend can encapsulate repeated behavior and reuse it across pages. The goal is to reduce behavior drift, shrink page modules, and make future feature work cheaper.

## Highest-Value Candidates

### Search Query Completions

Status: completed. Search query completions now live in shared modules:

- `Data.Search` owns `Completion`, completion generation, category query parsing, quoted category handling, and current-token replacement.
- `View.Search` owns completion dropdown rendering and Tab-key completion handling.

Before this refactor, `Page.FoodSearch` and `Page.MealForm` both implemented nearly identical search completion behavior:

- `Completion` variants for operators and category suggestions.
- `completions`, `completionLabel`, `applyCompletion`, and `categoryQuery`.
- Current-token parsing, quoted category handling, and whitespace handling.
- Completion dropdown rendering and dynamic height.
- Tab-key completion handling.

Keep future search query changes in these shared modules so the two pages do not drift.

### API Error Handling

Several pages repeat the same pattern:

- Check `Client.isUnauthorized`.
- Set a local error field to `Client.displayError error`.
- Return `SessionExpired` for 401 responses.
- Return `NoOp` for other failures.

This appears in pages such as `Page.Diary`, `Page.FoodDetail`, `Page.FoodLogDetail`, `Page.MealForm`, `Page.MealDetail`, `Page.Meals`, `Page.CustomFood.Create`, and `Page.CustomFood.Edit`.

Introduce a small helper module, for example `Page.ApiResult` or `Page.Error`, that standardizes unauthorized handling while still letting each page decide how to update its model.

### Page Loading/Error/Empty Shells

Many pages render the same page structure:

- `Ui.pageContainer`
- optional `Ui.errorBanner`
- loading state with `Ui.loading` or `Ui.skeletonLoading`
- empty state with `Ui.emptyState`
- content view when data is available

Candidates include `Page.Diary`, `Page.Meals`, `Page.FoodDetail`, `Page.FoodLogDetail`, `Page.MealDetail`, and custom food pages.

Add reusable UI helpers such as `Ui.pageError`, `Ui.pageBodyState`, or `Ui.loadablePage` to keep the page modules focused on domain-specific content.

### Dynamic Form Row Lists

The app repeats add/update/remove list-row logic in multiple form areas:

- Meal components in `Page.MealForm`.
- Nutrient rows in `Page.CustomFood.Form`.
- Serving rows in `Page.CustomFood.Form`.

`Data.ListExtra` already has useful primitives like indexed updates and removals. Build a slightly higher-level helper around these patterns for "add row", "remove row with minimum count", and "update row field".

### Quantity and Unit Controls

Amount/unit inputs and defaults appear in several places:

- Food log amount and unit in `Page.FoodLogForm`.
- Meal total quantity and unit in `Page.MealForm`.
- Meal detail nutrient preview quantity and unit in `Page.MealDetail`.
- Custom food default quantity/unit and serving quantity/unit in `Page.CustomFood.Form`.

Create a reusable `View.QuantityInput` or `View.UnitInput` for common labels, unit options, dropdown behavior, and default handling.

### Unit Defaults

The default unit `"g"` is scattered across forms and data conversion code. Centralize it in `Data.Units`, for example:

- `defaultCode : String`
- `defaultQuantity : String`
- helpers like `unitOrDefault` and `quantityOrDefault`

This keeps unit behavior consistent when defaults change or new unit rules are added.

### Delete Confirmation State and View

Delete confirmation behavior is currently local to detail/list pages, especially `Page.MealDetail` and meal deletion flows. Encapsulate the common behavior:

- confirmation open/closed state
- deleting state
- delete error message
- confirm/cancel/action buttons

A reusable `Ui.confirmDelete` view plus a small state helper would make future delete flows more consistent.

### Item and Product Name Lookup

Several places load item/product names after loading references:

- `Page.Diary` resolves item names for logs.
- `Page.MealDetail` resolves product names for meal components.
- `Page.MealForm` resolves product names while loading an existing meal.

Consider a shared lookup helper that deduplicates item references, tracks loaded names, and provides fallback names.

## Medium-Value Candidates

### Form Sections

`Page.CustomFood.Form` has a local `section` helper, while other forms manually combine headings, cards, and inputs. A shared `Ui.formSection` could standardize spacing and headings across form-heavy pages.

### Search Result Panel

`View.Search.resultRow` is shared, but each page still owns surrounding state rendering:

- searching/loading
- no results
- result list card
- optional "Create Custom Food" action

Create `View.FoodSearchPanel` if more pages need product search.

### Nutrient Preview Panel

`Page.MealForm` and `Page.MealDetail` both show nutrient preview state:

- loading nutrition
- nutrition error
- macro breakdown
- nutrients table

Extract a reusable `View.NutritionPreview` that composes `View.Nutrients.macroBreakdownView` and `View.Nutrients.nutrientsTable`.

### Shared API JSON Encoders

The API modules duplicate basic encoders:

- `itemRefEncoder`
- `quantityEncoder`
- `maybeStringEncoder`
- nullable quantity/string helpers

Move these into data/API helper modules such as `Data.ItemRef.encoder`, `Data.Quantity.encoder`, and `Api.Json.maybeString`.

### Action Rows

List rows with primary text plus trailing actions appear in meal lists and similar UI. A `Ui.actionRow` helper could standardize row spacing, borders, and button placement.

### Number Formatting

Number formatting lives in multiple places:

- `Data.Nutrition.oneDecimal`
- local amount formatting in `View.Nutrients`

Create a small `Data.NumberFormat` module for one-decimal and compact nutrient amount formatting.

## Lower-Value Optional Candidates

- `Ui.pill` for category pills and future tag-style UI.
- Standard submit/delete button labels for `Saving...`, `Deleting...`, and similar states.
- Route navigation helpers, only if route construction grows more complex.

## Recommended First Refactors

1. Extract search completion parsing and dropdown rendering. This is the clearest duplication and has the highest risk of behavior drift.
2. Extract API error handling for unauthorized/session-expired responses. This reduces boilerplate across most pages.
3. Extract quantity/unit defaults and controls. This touches several user-facing forms and makes unit behavior consistent.
4. Extract nutrient preview UI after the quantity/unit cleanup, since preview rendering depends on those inputs.
