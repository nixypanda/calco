# Frontend

## Overview

The active frontend is the Elm app in `frontend-web/`.

```text
frontend-web/
  src/
    Api/
    Data/
    Lib/
    Page/
    View/
    Main.elm
    Ui.elm
  tests/
  index.html
  vite.config.js
```

It is an Elm 0.19.1 `Browser.application` that talks to the Rust backend through HTTP JSON under `/api`. The app uses `mdgriffith/elm-ui` for layout and styling, with shared UI primitives centralized in `frontend-web/src/Ui.elm`.

The legacy React frontend has been removed. The current Elm app is built and served with Vite, and all frontend work lives in `frontend-web/`.

## Architecture

Every page module follows the canonical TEA (The Elm Architecture) pattern:

```elm
module Page.Diary exposing (Model, Msg, init, update, view, subscriptions)

type alias Model = { ... }
type Msg = ...

init : Args -> Session -> ( Model, Cmd Msg )
update : Msg -> Model -> ( Model, Cmd Msg )
view : Model -> Element Msg
subscriptions : Model -> Sub Msg
```

### Global State

`Main.elm` owns the top-level model and uses a `PageModel` ADT to scope page state:

```text
Model: key, route, session, bootstrap, page
PageModel = DiaryPage | MealDetailPage | FoodLogDetailPage | ... | NotFound
Msg: UrlChanged | LinkClicked | SessionLoaded | GotPage PageMsg
PageMsg = DiaryMsg | MealDetailMsg | ... (Cmd.map'd into Main.update)
```

### Page → App Boundary

When a page needs to signal the global layer (session expired, navigate), it returns an `OutMsg` from `update`:

```elm
type OutMsg = NoOp | SessionExpired | NavigateTo Route
```

`Main.update` branches on `OutMsg` to clear session, navigate, or do nothing.

### Invalid States

Frontend models should make important invalid states unrepresentable to a
pragmatic extent. Prefer types that describe the real states a page can be in
over records of independent `Maybe`s and booleans that can contradict each
other.

Use page-specific union types when state changes what data is available or
which actions are valid:

```elm
type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String
```

In this shape, `LoadedModel` should contain the data required to render the
loaded page without defensive `Maybe` checks:

```elm
type alias LoadedModel =
    { food : ProductDetail
    , units : List UnitItem
    , form : FoodLogForm.Model
    , request : RequestState
    }
```

Avoid loaded-page records like this when the fields are logically dependent:

```elm
type alias Model =
    { food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    , form : Maybe FoodLogForm.Model
    , error : Maybe String
    }
```

That record can represent states the UI should never see, such as a form
without its food, units without a form, or an error and loaded data competing
for the same screen.

Partial `Maybe`s are acceptable inside loading aggregators when independent
requests complete in any order:

```elm
type alias LoadingModel =
    { food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    }
```

Once all required data is present, transition to `Loaded`. Keep the partial
state scoped to loading instead of leaking it into the loaded model.

Model form and action lifecycles explicitly when they affect behavior:

```elm
type FormState
    = Editing Form
    | Invalid Form Problem
    | Submitting Form
    | Failed Form String

type RequestState
    = Idle
    | Saving
    | Deleting
```

This is especially useful for submit/delete flows, validation errors, and
stale async completions. If a completion should only apply while a matching
request is pending, store enough state to check that before updating the page.

The goal is not to eliminate every theoretical impossible state. It is to avoid
state shapes that force views and updates to repeatedly defend against
combinations that should not happen. Small, isolated state can still use a
generic `Loadable`:

```elm
type Loadable error value
    = NotAsked
    | Loading
    | Failure error
    | Success value
```

Use `Loadable` when all of its variants are meaningful for that local value.
Use a page-specific union when the page has dependent data, multiple requests,
or action state.

### API Errors

Backend error envelopes are preserved as an ADT in `Api.Client`:

```elm
type ApiError = BadUrl String | Timeout | NetworkError | BadStatus Int String String | BadBody String
```

### URL As Source Of Truth

`Browser.application` enforces URL-sourced state. Diary date, meal slot context, and other navigation-critical state live in query params, not in application state.

## Runtime Shape

`frontend-web/index.html` loads the compiled Elm bundle from `dist/main.js` and owns the small JavaScript bridge for the local date and IANA timezone:

- Elm calls the `requestLocalContext` port.
- JavaScript replies through `localContextReceived` with a `{ date, timezone }` record where `date` is the local `YYYY-MM-DD` (from `toLocaleDateString('en-CA')`) and `timezone` is the resolved IANA zone (from `Intl.DateTimeFormat().resolvedOptions().timeZone`).

Vite serves the frontend and proxies `/api/*` to the backend during local development. Defaults:

```text
frontend-web dev server: http://localhost:1234
API target: http://localhost:3001
```

Override with:

```bash
cd frontend-web && PORT=1235 API_TARGET=http://localhost:3001 npm run dev
```

## Routes

Current routes are defined in `frontend-web/src/Data/Route.elm`:

```text
/setup
/login
/admin
/admin/users/new
/admin/users/:id/edit
/home
/home?date=YYYY-MM-DD
/settings/goals
/logs/:id
/search
/search?date=YYYY-MM-DD
/search?meal_slot=:slot
/foods/:id
/foods/:id?date=YYYY-MM-DD
/foods/:id?meal_slot=:slot
/foods/custom
/foods/custom/new
/foods/custom/:id
/foods/custom/:id/edit
/meals
/meals/new
/meals/:id
/meals/:id/edit
/
*
```

Route access is enforced in `frontend-web/src/Access.elm` and coordinated from `frontend-web/src/Main.elm`:

- Bootstrap setup is available only while admin bootstrap is incomplete.
- Login is for unauthenticated sessions.
- Admin dashboard is for admin sessions.
- Diary, food, log, and meal routes are for normal authenticated user sessions.
- Admin identities do not own diary data, foods, logs, or meals.

## Pages

### Auth

- `Page.Users.BootstrapSetup`
- `Page.Users.Login`
- `Page.Users.Dashboard`
- `Page.Users.CreateUser`
- `Page.Users.EditUser`

The first-run flow creates a bootstrap admin. Admins create and manage normal user accounts.

### Diary

`Page.Diary.Day` is the main authenticated user screen.

It provides:

- Selected-day navigation.
- Calorie and macro summary.
- Goal-aware calorie and macro progress against the effective target for the selected day.
- Meal-slot grouped logs.
- Add-food actions per meal slot.
- App navigation drawer and profile/logout menu.

Users can inspect previous days with the diary date selector. A separate history/trends screen is out of scope.

### Goals

`Page.Goals.Settings` lets an authenticated user view and save calorie and macro targets for the current local day.

### Foods

- `Page.Food.Search`
- `Page.Food.Show`
- `Page.CustomFood.List`
- `Page.CustomFood.Create`
- `Page.CustomFood.Show`
- `Page.CustomFood.Edit`

Custom foods use the same catalog model as imported/global foods, scoped by user ownership.

### Logs

`Page.FoodLog.Entry` supports viewing, editing quantity/unit/meal slot/notes, and deleting a log.

Editing logged timestamp or swapping the selected item is intentionally not required for current scope.

### Meals

- `Page.Meal.List`
- `Page.Meal.Show`
- `Page.Meal.Create`
- `Page.Meal.Edit`
- `Page.Meal.Form`

Meal forms edit components inside the aggregate. There are no independent component screens.

## API Client

API modules live in `frontend-web/src/Api/`:

- `Auth.elm`
- `Admin.elm`
- `Foods.elm`
- `Goals.elm`
- `Logs.elm`
- `Meals.elm`
- `Client.elm`
- `Result.elm`

`Api.Client` centralizes request construction and API error handling. The frontend uses server-managed browser sessions, so requests rely on the browser session cookie.

## Design Direction

The UI should stay functional and food-diary oriented:

- Mobile-first responsive layouts. Small screens are the primary target, so UI/UX work should be designed and reviewed on mobile widths first.
- Fast repeated logging.
- Dense enough for daily use without becoming a spreadsheet.
- No marketing landing page.
- No analytics dashboard unless product scope changes.

Search, diary, and logging surfaces should prioritize compact, scannable controls and rows. Avoid oversized cards, large text that truncates early, or layouts that only work comfortably on desktop widths.

## Design System

Shared primitives live in `frontend-web/src/Ui.elm`. Prefer extending these helpers before styling one-off page elements.

Current visual language:

- `elm-ui` layout primitives, not CSS utility classes.
- Inter/system sans typography.
- Light theme page background `#f4f6f8`.
- White cards with 20px radius, 20px padding, and 12px internal spacing.
- Primary action color `#4b91cf` in light mode.
- Danger action color `#ff6b7a` in light mode.
- Muted gray text for captions and secondary content.
- Macro colors: protein pink/red, carbs green, fat amber.

Typography tokens in `Ui.elm` are intentionally restrained:

```text
page     28px desktop / 24px phone
section  22px desktop / 18px phone
subhead  17px desktop / 15px phone
body     14px
caption  12px
```

Control conventions:

- Use `Ui.button`, `Ui.submitButton`, `Ui.dangerButton`, and `Ui.smallButton` for actions.
- Use `Ui.input`, `Ui.passwordInput`, `Ui.select`, or `Ui.selectDropdown` for form fields.
- Use `Ui.card`, `Ui.emptyState`, `Ui.errorBanner`, `Ui.loading`, and `Ui.skeletonLoading` for common states.
- Use `Ui.badge` for compact metadata.
- Use `Ui.macroBar` for macro summaries.

Keep page-specific layout inside the owning page module, but shared look and feel should stay in `Ui.elm`.

## Tests

Elm frontend tests live in:

```text
frontend-web/tests
```

Run:

```bash
just frontend-web-test
```

Or directly:

```bash
cd frontend-web
elm-test
```

Build:

```bash
just frontend-web-build
```

Or directly:

```bash
cd frontend-web
mkdir -p dist
elm make src/Main.elm --output=dist/main.js
```

Useful frontend-web checks:

```bash
just frontend-web-format
just frontend-web-review
just frontend-web-line-length
just frontend-web-test
just frontend-web-build
```

No browser e2e suite is configured at the moment.
