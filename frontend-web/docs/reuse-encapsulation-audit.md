# Frontend Reuse Encapsulation Audit

This audit lists the main places where the current Elm frontend can still encapsulate repeated behavior and reuse it across pages. The goal is to reduce behavior drift, shrink page modules, and make future feature work cheaper.

## Highest-Value Candidates

### Page Loading/Error/Empty Shells

Many pages render the same page structure:

- `Ui.pageContainer`
- optional `Ui.errorBanner`
- loading state with `Ui.loading` or `Ui.skeletonLoading`
- empty state with `Ui.emptyState`
- content view when data is available

Candidates include `Page.Diary.Index`, `Page.Meal.Index`, `Page.Food.Detail`, `Page.FoodLog.Detail`, `Page.Meal.Detail`, and custom food pages.

Add reusable UI helpers such as `Ui.pageError`, `Ui.pageBodyState`, or `Ui.loadablePage` to keep the page modules focused on domain-specific content.

### Dynamic Form Row Lists

The app repeats add/update/remove list-row logic in multiple form areas:

- Meal components in `Page.Meal.Form`.
- Nutrient rows in `View.CustomFoodForm`.
- Serving rows in `View.CustomFoodForm`.

`Lib.ListExtra` already has useful primitives like indexed updates and removals. Build a slightly higher-level helper around these patterns for "add row", "remove row with minimum count", and "update row field".

### Quantity and Unit Controls

Amount/unit inputs appear in several places:

- Food log amount and unit in `View.FoodLogForm`.
- Meal total quantity and unit in `Page.Meal.Form`.
- Meal detail nutrient preview quantity and unit in `Page.Meal.Detail`.
- Custom food default quantity/unit and serving quantity/unit in `View.CustomFoodForm`.

Create a reusable `View.QuantityInput` or `View.UnitInput` for common labels, unit options, dropdown behavior, and default handling. Keep shared defaults and unit option behavior in `Data.Units`.

### Item and Product Name Lookup

Several places load item/product names after loading references:

- `Page.Diary.Index` resolves item names for logs.
- `Page.Meal.Detail` resolves product names for meal components.
- `Page.Meal.Form` resolves product names while loading an existing meal.
- `Page.FoodLog.Detail` resolves the logged item name.

Consider a shared lookup helper that deduplicates item references, tracks loaded names, and provides fallback names.

## Medium-Value Candidates

### Nutrient Preview Panel

`Page.Meal.Form` and `Page.Meal.Detail` both show nutrient preview state:

- loading nutrition
- nutrition error
- macro breakdown
- nutrients table

Extract a reusable `View.NutritionPreview` that composes `View.Nutrients.macroBreakdownView` and `View.Nutrients.nutrientsTable`.

### Delete Confirmation State and View

Delete confirmation behavior is local to `Page.Meal.Detail`, and future delete flows are likely to need similar state and UI:

- confirmation open/closed state
- deleting state
- delete error message
- confirm/cancel/action buttons

A reusable `Ui.confirmDelete` view plus a small state helper would make future delete flows more consistent.

### Form Sections

`View.CustomFoodForm` has a local `section` helper, while other forms manually combine headings, cards, and inputs. A shared `Ui.formSection` could standardize spacing and headings across form-heavy pages.

### Search Result Panel

`View.Search.resultRow` is shared, but each page still owns surrounding state rendering:

- searching/loading
- no results
- result list card
- optional "Create Custom Food" action

Create `View.FoodSearchPanel` if more pages need product search.

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

1. Extract nutrient preview UI. It has visible duplication and a clear composition point around existing `View.Nutrients` helpers.
2. Extract quantity/unit controls. This touches several user-facing forms and should build on the existing `Data.Units` helpers.
3. Extract item/product name lookup once the desired lookup state shape is clear across diary, meal, and food-log pages.
4. Extract page loading/error/empty shells only if the helper stays simple enough to avoid hiding page-specific behavior.
5. Extract dynamic form row helpers after the quantity/unit cleanup, since row abstractions are easier to shape once shared controls exist.
