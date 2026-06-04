# Frontend Reuse Encapsulation Audit

This audit lists the main places where the current Elm frontend can still encapsulate repeated behavior and reuse it across pages. The goal is to reduce behavior drift, shrink page modules, and make future feature work cheaper.

## Highest-Value Candidates

### Dynamic Form Row Lists

The app repeats add/update/remove list-row logic in multiple form areas:

- Meal components in `Page.Meal.Form`.
- Nutrient rows in `View.CustomFoodForm`.
- Serving rows in `View.CustomFoodForm`.

`Lib.ListExtra` already has useful primitives like indexed updates and removals. Build a slightly higher-level helper around these patterns for "add row", "remove row with minimum count", and "update row field".

## Medium-Value Candidates

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

1. Extract dynamic form row helpers, since row abstractions are easier to shape now that shared quantity/unit controls exist.
