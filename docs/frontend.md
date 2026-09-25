# Frontend

## Overview

The active frontend is the Elm app in `frontend-web/`.

```text
frontend-web/
  src/
    Api/
    Component/
    Data/
    Lib/
    Page/
    Ui/
    View/
    Access.elm
    Chrome.elm
    Main.elm
    Page.elm
    barcodeScanner.js
    index.js
  tests/
  index.html
  vite.config.js
```

It is an Elm 0.19.2 `Browser.application` that talks to the Rust backend
through HTTP JSON under `/api`. The app uses `mdgriffith/elm-ui` for layout
and styling, with shared UI primitives centralized in the
`frontend-web/src/Ui/` module family.

The legacy React frontend has been removed. All active frontend work lives in
`frontend-web/`.

## Architecture

The frontend follows a strict ownership model:

```text
Main -> Access / Chrome / Data.Route / Page
Chrome -> View.Chrome / Data / Ui
Page -> Store / Component / Data / Api / Ui / View / Lib
Component -> Data / Api types / Ui / View / Lib
Store -> Api.Client / Data / Lib
View -> Ui / Data / Lib
Api -> Api.Client / Data decoders / Lib.Json
Data -> other Data / Lib
Ui -> Ui.Theme / Data / Lib
```

Disallowed dependency directions:

- `Data` importing `Page`, `Main`, or `Api`.
- `Component` owning routes, page orchestration, or HTTP execution.
- `Ui` importing page-specific modules.
- `Api` owning page state, navigation decisions, or view formatting.
- `View` triggering HTTP or owning page orchestration.

This keeps the composition root in one place, keeps pages readable, and
prevents domain shaping from drifting into transport or presentation layers.

### Module Ownership

`Main.elm` is the app-wide composition root. It owns:

- URL changes and browser navigation.
- session/bootstrap loading.
- coordination between app chrome and the active page.
- routing into the correct page model.

`Chrome.elm` coordinates top-level device, navigation, profile, and theme
state. `View.Chrome` renders the responsive shell.

`Access.elm` is the single route-access policy point. It decides whether a
route should render, redirect, or wait for session/bootstrap state.

`Data.Route.elm` is the single source of truth for route parsing and route
serialization. Query-param-backed navigation state belongs here.

`Page.*` modules own page-local TEA, page-local loading/submitting/deleting
state, and page-specific composition of shared UI and API calls.

`Component.*` modules own reusable nested TEA state and stateful forms. A
component used by multiple page categories lives directly under `Component`;
components reused only within one category remain in a matching subdirectory.
Components may use API request and response types, but pages retain ownership
of executing HTTP commands and interpreting navigation or session effects.

`Store.elm` owns session-scoped server data and date-keyed diary data. It lives
at the top level because cached failures use `Api.Client.ApiError`; putting that
dependency under `Data` would reverse the allowed dependency direction. The store
is opaque: callers name a resource through `Store.Access` and reach it only via
`request`, `settle`, `cached`, `seed` and `invalidate`, so which field or
dictionary key backs a resource stays inside the module.

`request` issues at most one in-flight request per resource and hands back an
opaque `RequestToken`; recording a result requires redeeming that token through
`settle`, which rejects a response from an earlier session, one whose request a
mutation has since invalidated, and a duplicate of one already settled. Because
the only way to write is to redeem, the staleness check cannot be omitted at a
call site.

`Page` orchestration describes each cached resource once — where it lives, how to
fetch it, and which panes it feeds — and drives every one of them through the
same generic ensure/settle/hydrate path. Newly initialized panes are hydrated
from whatever is already cached; panes the reconcile reused are left alone.

Top-level `Page.Model` owns an ordered stack of independently keyed panes.
Route changes reconcile the desired stack by key: unchanged panes keep their
local state and issue no initialization request, new identities initialize once,
and panes absent from the destination are dropped. A pane key includes the
entity or date context whenever reusing state across those values would be
incorrect. A small context-selection layer preserves lineage-dependent
workspaces, such as opening a food from search, because that lineage is not
encoded in `Data.Route`.

Successful food-log mutations explicitly invalidate matching diary and calendar
panes, plus cached latest-slot suggestions whose lookback window may include the
changed date. Do not rely on navigation to reinitialize a pane as a refresh
mechanism.

`Api.*` modules own request construction, response decoding, and transport
errors. They do not own business interpretation beyond transport concerns.

`Data.*` modules own domain-facing frontend types and pure helpers. They should
be safe to test in isolation without HTTP or page wiring.

The `Ui.*` module family and `View.*` own shared presentation primitives. Pages
compose them, but should not copy their look-and-feel logic locally unless the
pattern is truly one-off.

## Page Structure

Every non-trivial `Page.*` module should follow canonical TEA and should be
organized so the high-level sections are obvious when scanning the file.

Expected minimum shape:

```elm
module Page.SomePage exposing (Model, Msg, init, update, view)

-- MODEL

type alias Model = ...

init : Args -> Model
init args =
    ...


-- UPDATE

type Msg
    = ...

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    ...


-- VIEW

view : ViewArgs -> Model -> Element Msg
view args model =
    ...
```

When a page needs to signal the app layer or own subscriptions, extend the
shape explicitly:

```elm
module Page.SomePage exposing
    ( Model
    , Msg
    , OutMsg(..)
    , init
    , update
    , view
    , subscriptions
    )

type OutMsg
    = NoOp
    | Navigate Route
    | SessionExpired


init : Args -> ( Model, OutMsg )
init args =
    ...


-- UPDATE

type Msg
    = ...

update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    ...


-- VIEW

view : ViewArgs -> Model -> Element Msg
view args model =
    ...


-- SUBSCRIPTIONS

subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.none
```

Rules:

- Each page should own `Model`, `Msg`, `init`, `update`, and its view logic.
  Pane modules expose `contentView` when the top-level workspace owns the page
  container; standalone-only modules expose `view`.
- Add `OutMsg` when the page must signal app-level effects such as navigation,
  session expiration, or startup orchestration.
- Add `subscriptions` only when the page owns actual subscriptions.
- `init` may return either a bare `Model` or `( Model, OutMsg )` depending on
  whether startup coordination is needed.
- In non-trivial page modules, prefer three primary sections:
  `-- MODEL`, `-- UPDATE`, and `-- VIEW`.
- Keep model definitions, submodels, optional `OutMsg`, and `init` together
  under `-- MODEL`.
- Keep `Msg`, `update`, and update-oriented helpers together under
  `-- UPDATE`.
- Keep `view` and view-oriented helpers together under `-- VIEW`.
- Add optional sections like `-- SUBSCRIPTIONS` or `-- PORTS` only when the
  module actually has them.
- Add `-- HELPERS` only when helper volume is large enough that keeping them
  inside `-- UPDATE` or `-- VIEW` would hurt scanability.
- Do not force ceremony into tiny helper modules. This rule is for page
  readability, not comment noise.

### Page To App Boundary

When a page needs to signal the global layer, it should return an `OutMsg`
rather than reaching indirectly into app concerns.

Allowed examples:

```elm
type OutMsg
    = NoOp
    | Navigate Route
    | SessionExpired
    | RequestDiaryData LocalDate
```

Disallowed examples:

```elm
-- Page decides to mutate global session directly.

-- Page reconstructs app-wide route access rules locally.

-- Page hides navigation inside an opaque helper in Api.*
```

If an effect changes global navigation, session state, or app-level loading
behavior, surface it as an `OutMsg` and let `Main.update` coordinate it.

## State Modeling

Frontend models should make important invalid states unrepresentable to a
pragmatic extent. Prefer ADTs that describe the real states a page can be in
over records of independent `Maybe`s and booleans that can contradict each
other.

### Use ADTs To Disallow Invalid States

Prefer page-specific union types when state changes what data is available or
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

### Keep It Pragmatic

This is not a rule to invent ceremony everywhere.

Allowed:

- `Maybe` for genuinely optional single values.
- `Loadable` for small isolated values where every variant is meaningful.
- simple records when all fields are independently valid.

Preferred:

- page-specific ADTs for loading/loaded/failed flows.
- action-state ADTs for submit/delete/save flows.
- narrow unions when behavior changes materially by state.

Disallowed:

- records full of unrelated flags that require the view to re-check impossible
  combinations repeatedly.
- shoving partial loading state into the loaded model.
- using booleans like `isLoading`, `hasLoaded`, and `hasError` together when a
  union type would express the state directly.

### Loading Aggregation

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

### Form And Request State

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

## Routing And Access

`Browser.application` makes URL-backed state a core part of the architecture.
Navigation-critical state should live in routes or query params, not in hidden
application state.

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
/settings/diary
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

Rules:

- Diary date, meal-slot context, and similar navigation-critical state belong
  in route parameters or query params.
- `Data.Route` owns parsing and serialization of that state.
- `Access.resolveRoute` owns access policy for bootstrap-only, anonymous,
  admin-only, and normal authenticated routes.
- Admin identities do not own diary data, foods, logs, or meals.
- Do not reconstruct route strings ad hoc in page modules.

Allowed examples:

```elm
Navigate (FoodSearch (Just date) (Just slot))
```

Disallowed examples:

```elm
NavigateToPath ("/search?date=" ++ date ++ "&meal_slot=" ++ slot)
```

## API Boundary

API modules live in `frontend-web/src/Api/`:

- `Auth.elm`
- `Admin.elm`
- `Foods.elm`
- `DiaryPreferences.elm`
- `Goals.elm`
- `Logs.elm`
- `Meals.elm`
- `Client.elm`

`Api.Client` centralizes request construction and API error handling. The
frontend uses server-managed browser sessions, so requests rely on the browser
session cookie.

Backend error envelopes are preserved as an ADT in `Api.Client`:

```elm
type ApiError
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Int String String
    | BadBody String
```

Rules:

- `Api.*` owns transport details and decoding.
- `Page.*` owns what the data means for the screen.
- transport failures should be normalized through `Api.Client.ApiError`.
- session-expired behavior should be surfaced through page `OutMsg` and handled
  in `Main`.
- do not bury navigation or page-state transitions inside API helpers.

The frontend boundary should stay: request/response in `Api`, business meaning
in `Data` and `Page`, app coordination in `Main`.

## Runtime Shape

`frontend-web/src/index.js` is the Vite entry point. It initializes Elm and
owns the JavaScript ports for:

- local date and IANA timezone.
- persisted theme preference.
- requested page reloads.
- camera barcode scanning through `barcodeScanner.js`.

The scanner uses ZXing for EAN/UPC detection and stops camera tracks when the
scan completes or is cancelled.

Vite serves the frontend and proxies `/api/*` to the backend during local
development. Defaults:

```text
frontend-web dev server: http://localhost:1234
API target: http://localhost:3001
```

Override with:

```bash
cd frontend-web
API_TARGET=http://localhost:3001 npm run dev -- --host 127.0.0.1 --port 1235
```

## Pages

### Auth

- `Page.Users.BootstrapSetup`
- `Page.Users.Login`
- `Page.Users.Dashboard`
- `Page.Users.CreateUser`
- `Page.Users.EditUser`

The first-run flow creates a bootstrap admin. Admins create and manage normal
user accounts.

### Diary

`Page.Diary.Day` is the main authenticated user screen.

It provides:

- selected-day navigation.
- calorie and macro summary.
- goal-aware calorie and macro progress against the effective target for the
  selected day.
- meal-slot grouped logs.
- add-food actions per meal slot.
- recent-item quick add and latest-slot repeat actions.
- bottom navigation on phones and a drawer on larger screens.

Users can inspect previous days with the diary date selector. A separate
history/trends screen is out of scope.

`Page.Diary.Settings` lets users select which meal slots appear in their diary.

### Goals

`Page.Goals.Settings` lets an authenticated user view and save calorie and
macro targets for the current local day.

### Foods

- `Page.Food.Search`
- `Page.Food.Show`
- `Page.CustomFood.List`
- `Page.CustomFood.Create`
- `Page.CustomFood.Show`
- `Page.CustomFood.Edit`

Custom foods use the same catalog model as imported/global foods, scoped by
user ownership.

Food search supports manual barcode lookup and camera scanning on compatible
devices. Both use the same local-first API: a local match opens immediately,
while a catalog miss is fetched from Open Food Facts, persisted, and then
opened. The food detail page displays the API-provided import note for a newly
fetched product. If neither source has the barcode, the existing not-found
state offers custom-food creation. A `404` gets a barcode-specific not-found
message; other failures retain the API error message in the error banner, while
the custom-food action remains available.

### Logs

`Page.FoodLog.Entry` supports viewing, editing quantity/unit/meal slot/notes,
and deleting a log.

Editing logged timestamp or swapping the selected item is intentionally not
required for current scope.

### Meals

- `Page.Meal.List`
- `Page.Meal.Show`
- `Page.Meal.Create`
- `Page.Meal.Edit`
- `Page.Meal.Form`

Meal forms edit components inside the aggregate. There are no independent
component screens.

## Design Direction

The UI should stay functional and food-diary oriented:

- mobile-first responsive layouts. Small screens are the primary target.
- fast repeated logging.
- dense enough for daily use without becoming a spreadsheet.
- no marketing landing page.
- no analytics dashboard unless product scope changes.

Search, diary, and logging surfaces should prioritize compact, scannable
controls and rows. Avoid oversized cards, large text that truncates early, or
layouts that only work comfortably on desktop widths.

### Responsive Design Rule

Keep a consistent, fluid default and introduce a breakpoint only when the
information architecture or interaction model must materially change.

Prefer shared spacing, control sizes, wrapping, and visible content across
viewport sizes. Use responsive branches for structural changes such as pane
count, navigation mode, or fields that must stack to remain usable. Do not use
device size as a proxy for input capabilities such as touch, hover, or pointer
precision; handle those with the corresponding browser capability where
needed.

### Repeat Logging UI

- Empty meal-slot cards should show a compact repeat action when the backend
  finds a recent source slot. Use a single button label with source-date
  context, such as `Log latest from Jun 19, 2026`.
- If no source exists within the lookback window, keep showing the passive
  `No items` state.
- Keep `Add Food` as the path into search and manual selection.
- Recent slot suggestions in the add/search flow are separate from `Log latest`:
  show deduplicated foods and meals used in the same slot recently, so users can
  quickly log a subset without copying the whole prior slot.
- Each recent row offers up to five quantity chips, ordered by how often that
  quantity was logged for the item. Tapping a chip logs that quantity directly;
  tapping the row still opens the full log form for any other quantity.

## Design System

Shared primitives live in the `frontend-web/src/Ui/` module family. Prefer
extending these helpers before styling one-off page elements.

Current visual language:

- `elm-ui` layout primitives, not CSS utility classes.
- Inter/system sans typography.
- light theme page background `#f4f6f8`.
- cards with a subtle primary-color tint (`#fafdfe` light, `#1e2630` dark) and a stronger tint on header bands (`#ecf6fc` light, `#212f3b` dark), 20px radius, 20px padding, and 12px internal spacing. The dark header tint is capped so muted header text keeps at least 4.5:1 contrast.
- primary action color `#4b91cf` in light mode.
- danger action color `#ff6b7a` in light mode.
- muted gray text for captions and secondary content.
- macro colors: protein pink/red, carbs green, fat amber.

Typography tokens in `Ui.Typography` are intentionally restrained:

```text
page     32px
section  24px
subhead  20px
body     16px
caption  13px
```

Control conventions:

- use `Ui.primarySubmitButton`, `Ui.secondarySubmitButton`,
  `Ui.fullWidthDangerButton`, and icon-button helpers for actions.
- use `Ui.input`, `Ui.passwordInput`, and `Ui.selectDropdown` for
  form fields.
- use `Ui.card`, `Ui.emptyState`, `Ui.errorBanner`, `Ui.loading`, and
  `Ui.skeletonLoading` for common states.
- use `Ui.panel` when several related blocks belong under one header: the panel
  owns one tinted header band and its sub-blocks use plain-text titles separated
  by hairlines. Reserve a headerless `Ui.card` for content inside a panel or a
  block that genuinely has no heading. Use `Ui.section` for a single titled
  block on its own surface.
- use `Ui.badge` for compact metadata.
- use `Ui.statBlockGroup` and progress helpers for nutrition summaries.

Rules:

- prefer existing `Ui.*` primitives before building local one-off styles.
- move a pattern into `Ui` or `View` once it is reused or clearly foundational.
- keep page-specific layout in the owning page module.
- do not bypass `elm-ui` with ad hoc CSS-heavy page structures unless the
  browser integration genuinely requires it.

Accepted deviations:

- The light-mode macro accent fills (`calorieAccent`, `proteinAccent`,
  `carbsAccent`, `fatAccent`) sit below the 3:1 non-text contrast target
  against `cardBg`/`inputFill`. This is a deliberate palette choice and is
  waived in review; do not darken them without a design decision.

## Tests

Elm frontend tests live in:

```text
frontend-web/tests
```

Run:

```bash
just test-frontend
```

Or directly:

```bash
cd frontend-web
elm-test
```

Useful frontend-web checks:

```bash
just check-frontend-line-length
just check-frontend-review
just test-frontend
just format-frontend
just build-frontend
```

Build:

```bash
just build-frontend
```

Or directly:

```bash
cd frontend-web
npm run build
```

No browser e2e suite is configured at the moment.
