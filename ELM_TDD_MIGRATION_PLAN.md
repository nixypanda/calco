# Elm TDD Migration Plan

This document is the test-first companion to `ELM_ARCHITECTURE_PLAN.md`.

The goal is to replicate the current React frontend feature-for-feature in Elm,
without caring about pixel-level visual parity. The React app remains in
`frontend/` as the production reference while the Elm app coexists in
`frontend-web/`. Once the Elm app is fully fleshed out and verified, the React
frontend can be removed.

The migration should prove behavior first: write user stories, turn them into
pure tests, implement page state and helper logic, then wire HTTP commands and
minimal `elm-ui` views.

The Elm frontend should use `mdgriffith/elm-ui` for layout and styling. Do not
use Tailwind classes, ad hoc CSS class strings, or a parallel CSS utility system
for application UI. Keep styling in Elm values and small shared `Ui/*` helpers.

The current React app implements:

- first-time admin setup
- login, logout, session bootstrap, and route guards
- admin user management
- diary day navigation, grouped logs, calories, and macros
- food search
- food detail and product logging
- food log view/edit/delete
- custom food create/edit
- meals list, create/edit, detail, nutrient preview, log, and delete

Import administration is intentionally not part of the browser frontend. Import
tooling remains CLI/API driven.

## Current Status

Last updated after the Phase 12 Elm meal detail/logging implementation.

Implemented through **Phase 12: Meal Detail And Meal Logging** in
`frontend-web/`. The Elm app now has a real `Browser.application` shell, route
parsing, access decisions, session bootstrap, login, first-time admin setup,
logout, and admin user management flows, plus the real diary `/home` page with
day navigation, grouped logs, daily summary macros/calories, item-name lookup,
and diary navigation intents. Food tracking routes now cover `/search`,
`/foods/:id`, `/logs/:id`, custom food create/edit, meals list, meal create/edit,
meal detail, meal nutrient preview, meal logging, and meal deletion. The React
frontend in `frontend/` remains untouched and is still the behavioral reference
for later phases.

### Completed

- Phase 0 test harness:
  - Replaced the placeholder Elm test with focused tests for routes, access,
    session, JSON contracts, local dates, nutrition parsing, auth forms, and
    admin dashboard state transitions.
  - Current frontend-web test count: `53`.
  - Verified with `just frontend-web-test`.
- Phase 1 routing and access:
  - Added `src/Route.elm` and `src/Access.elm`.
  - Supports the planned paths through meals/foods/logs, including
    `meal_slot` and diary `date` query params.
  - Implements root redirect behavior, admin route guards, and food-tracking
    route guards.
- Phase 2 API contracts:
  - Added `src/Api/Client.elm`, `src/Api/Auth.elm`, and `src/Api/Admin.elm`.
  - Added auth/user/quantity/item-ref data modules used by the implemented
    phases.
  - `Api.Client` uses `Http.expectStringResponse` so backend error envelopes are
    preserved as `BadStatus status code message`.
  - Do not manually add a `Content-Type` header for JSON requests. `Http.jsonBody`
    sets it; adding another one can produce a combined header that Axum rejects.
- Phase 3 session and auth pages:
  - Added `src/Session.elm`, `src/Page/Login.elm`, and
    `src/Page/BootstrapAdminSetup.elm`.
  - Session/bootstrap load in `Main.init`.
  - Login/setup pages use pure validation helpers and return out-messages for
    HTTP commands and navigation.
- Phase 4 admin dashboard:
  - Added `src/Page/AdminDashboard.elm`.
  - Supports listing users, creating users, resetting passwords, disabling, and
    enabling users.
  - Failed admin actions preserve existing loaded user data and show errors.
  - `401` admin failures clear session and navigate to login through the app
    shell.
- Phase 5 diary:
  - Added `src/Page/Diary.elm`.
  - Added diary data/API support for log lists, summaries, product and meal
    item-name lookup, local date arithmetic, grouped logs, calories, and macro
    totals.
  - Wired `/home` in `Main.elm` to the real diary page instead of placeholder
    text.
  - Supports valid/invalid/missing `date` query handling, previous/next day
    navigation capped at today, grouped breakfast/lunch/dinner/snack/other logs,
    daily summary calories/macros, macro grams/percent toggle, add-food
    navigation with meal slot context, log-detail navigation, meals navigation,
    and failed load display.
  - Name lookup failures use explicit unknown food/meal fallbacks.
  - Current frontend-web test count: `73`.
- Phase 6 food search:
  - Added `src/Page/FoodSearch.elm`.
  - Extended `src/Api/Foods.elm` with food search DTOs, response decoders,
    encoded search paths, and the `/api/foods/search?q=...` request.
  - Wired `/search` in `Main.elm` to the real Elm page instead of placeholder
    text.
  - Supports debounced non-empty searches, empty query clearing, loading and
    error states, stale response/failure ignoring via request tokens, no-result
    custom-food create navigation, food-detail selection, and barcode display
    for numeric queries.
  - Preserves `meal_slot` query context from `/search?meal_slot=...` when
    navigating to `/foods/:id?meal_slot=...`.
  - Current frontend-web test count: `86`.
- Phase 7 food detail and product logging:
  - Added `src/Page/FoodDetail.elm` and `src/Page/FoodLogForm.elm`.
  - Extended `src/Api/Foods.elm` with product detail, nutrient, serving, and
    unit DTOs/decoders plus food-detail and unit-list requests.
  - Extended `src/Api/Logs.elm` with create-log request encoding and the
    `/api/logs` create request.
  - Wired `/foods/:id` in `Main.elm` to the real Elm page instead of
    placeholder text.
  - Added a browser port backed by `index.html` for React-compatible
    `localISOString()` timestamp creation with timezone offset.
  - Supports detail/unit loading, default quantity/unit fallback to `1 g`,
    optional meal slot and notes encoding, product log creation, success
    navigation back home, failure state preservation, and custom-food edit
    navigation for `source == "USER"`.
  - Current frontend-web test count: `107`.
- Phase 8 food log detail/edit/delete:
  - Added `src/Page/FoodLogDetail.elm`.
  - Reused and extended `src/Page/FoodLogForm.elm` for existing-log
    initialization and update-log request construction.
  - Extended `src/Api/Client.elm` with `PUT` and `DELETE` helpers.
  - Extended `src/Api/Logs.elm` with get/update/delete requests and update
    payload encoding.
  - Wired `/logs/:id` in `Main.elm` to the real Elm page instead of placeholder
    text.
  - Supports log/unit loading, product-detail or meal-name resolution, editing
    quantity/unit/meal slot/notes, explicit `meal_slot: null` and blank notes as
    `null`, update success replacement, update/delete failure preservation, and
    delete success navigation home.
  - Current frontend-web test count: `122`.
- Phase 9 custom food create/edit:
  - Added `src/Page/CustomFood/Form.elm`, `src/Page/CustomFood/Create.elm`, and
    `src/Page/CustomFood/Edit.elm`.
  - Extended `src/Api/Foods.elm` with nutrient catalog, custom-food create, and
    custom-food update requests/encoders.
  - Wired `/foods/custom/new` and `/foods/custom/:id/edit` in `Main.elm` to real
    Elm pages instead of placeholder text.
  - Supports one-row empty nutrient defaults, name validation, category
    normalization/deduplication, incomplete nutrient/serving row filtering,
    blank optional values as `null`, product-detail-to-form mapping for edits,
    save success navigation to food detail, and save failure state preservation.
- Phase 10 meals list:
  - Added `src/Page/Meals.elm`.
  - Extended `src/Api/Meals.elm` with meal list/detail DTOs and list requests.
  - Wired `/meals` in `Main.elm` to the real Elm page instead of placeholder
    text.
  - Supports loading, empty state detection, load errors, open-meal navigation,
    create-meal navigation, and back navigation home.
- Phase 11 meal form:
  - Added `src/Page/MealForm.elm`.
  - Extended `src/Api/Meals.elm` with create/update meal request encoding and
    create/update requests.
  - Wired `/meals/new` and `/meals/:id/edit` in `Main.elm` to the real Elm form
    page instead of placeholder text.
  - Supports create and edit modes, product-only component rows, product-name
    hydration for edit rows, per-row product search with request-token stale
    response protection, component add/remove, name and selected-product
    validation, optional total quantity encoding, default component quantity
    `100 g`, save success navigation to meal detail, and save failure state
    preservation.
- Phase 12 meal detail and meal logging:
  - Added `src/Page/MealDetail.elm`.
  - Extended `src/Api/Meals.elm` with delete and nutrient-preview requests.
  - Wired `/meals/:id` in `Main.elm` to the real Elm page instead of placeholder
    text.
  - Reused `Api.Logs.createLog` and the browser local timestamp port for meal
    logging.
  - Supports meal/component loading, unique product-name resolution, unit
    loading, amount/unit nutrient preview with request-token stale response
    protection, invalid amount clearing, meal log payloads using
    `item.type = "meal"`, log success navigation home, log failure state
    preservation, delete confirmation open/close, delete success navigation to
    meals, delete failure preservation, and edit navigation.
  - Current frontend-web test count: `152`.
- UI/dev workflow:
  - Added a small `src/Ui.elm` vocabulary using `mdgriffith/elm-ui`.
  - Added `frontend-web/dev-server.mjs` for local static serving plus `/api`
    proxying to `http://localhost:3001`, matching the React frontend's Vite
    proxy behavior.
  - Added/updated Just recipes:
    - `just frontend-web-test`
    - `just frontend-web-build`
    - `just frontend-web-review`
    - `just frontend-web-dev`
  - Aggregate `just test` and `just build` now include `frontend-web`.

### Verified

```bash
nix develop -c just frontend-web-test
nix develop -c just frontend-web-build
```

Both passed at the Phase 12 stop point. `just frontend-web-build` and
`just frontend-web-test` require the Nix dev shell on machines where `elm` and
`elm-test` are not installed directly.

### Notes For The Next Phase

- The app intentionally stops after meal detail/logging. Shared helper
  extraction, browser theme/local-storage ports, and the broader Elm UI layer
  remain for later phases.
- `Api.Foods` now exposes diary product-name lookup, food search, food detail,
  units, nutrients, and custom-food create/update support.
- `Api.Meals` now exposes meal name lookup, list/detail, create/update/delete,
  and nutrient preview support.
- `Api.Logs` now exposes diary list/summary, create-log, and log
  get/update/delete. Product and meal logging both reuse the same create-log
  support.
- `Data.FoodLog`, `Data.LocalDate`, and `Data.Nutrition` contain the shared data
  helpers currently needed by the migrated pages. Phase 13 should decide which
  page-local helpers are worth promoting to shared pure modules.
- `frontend-web/dev-server.mjs` is deliberately minimal. A future pass can
  replace it with Vite or another standard dev server if the Elm app gets an npm
  toolchain.
- `.gitignore` explicitly unignores `frontend-web/src/Data/*.elm` because the
  repo-level `data/` import-pipeline ignore rule would otherwise hide Elm
  modules in a directory named `Data`.

## Testing Philosophy

Most tests should be pure Elm tests. Avoid UI snapshot tests and exact markup
assertions.

High-value tests:

- route parsing
- route access and redirect decisions
- session/auth state transitions
- JSON decoders and encoders
- form validation
- request payload construction
- page `update` transitions
- derived helpers for dates, nutrition, grouping, and display data
- stale async response handling through request tokens

Low-value tests:

- CSS classes
- exact HTML shape
- visual layout
- loading skeleton markup
- snapshot testing

For each feature slice, use this order:

1. Write user stories.
2. Write pure tests.
3. Implement `Model`, `Msg`, `init`, `update`, and pure helpers.
4. Implement decoders, encoders, and request payload builders.
5. Add `Cmd` wiring and API calls.
6. Add minimal `elm-ui` `view`.

The desired shape for page modules is:

```elm
module Page.Diary exposing (Model, Msg, init, update, view, subscriptions)

import Element exposing (Element)

type alias Model =
    ...

type Msg
    = ...

init : Args -> Session -> ( Model, Cmd Msg )
update : Msg -> Model -> ( Model, Cmd Msg )
view : Model -> Element Msg
subscriptions : Model -> Sub Msg
```

Tests should usually target pure functions beneath or beside `update`. When a
page has command-producing behavior, split the pure decision from the command
construction where useful:

```elm
updatePure : Msg -> Model -> ( Model, Effect )
runEffect : Effect -> Cmd Msg
```

Do not introduce an effect runtime by default. Use this only when a page is hard
to test directly through `update`.

## Phase 0: Elm Test Harness

### User Stories

- As a developer, I can run Elm tests for the new frontend.
- As a developer, I can test page logic without rendering the browser UI.
- As a developer, I can test backend JSON contracts before connecting pages.

### Tests

Create the first test modules:

```txt
tests/RouteTest.elm
tests/SessionTest.elm
tests/JsonDecoderTest.elm
tests/NutritionTest.elm
tests/LocalDateTest.elm
```

Initial test cases:

- `Route.fromUrl` parses known routes.
- `Session.init` starts in loading/bootstrap state.
- Basic auth session JSON decodes.
- Basic quantity and item references decode.
- `LocalDate.format` formats `YYYY-MM-DD`.
- Nutrition amount parsing treats invalid and negative values as `0`.

### Code

Use the existing `frontend-web/` Elm app directory for the parallel migration.
Keep `frontend/` intact as the React reference until Elm reaches feature parity.

Expected packages:

- `elm/browser`
- `elm/core`
- `elm/html`
- `elm/http`
- `elm/json`
- `elm/time`
- `elm/url`
- `mdgriffith/elm-ui`
- `elm-explorations/test`
- optional: `krisajenkins/remotedata`
- optional: a local-date package if a small `YYYY-MM-DD` wrapper is not enough

Do not commit generated Elm artifacts such as `elm-stuff/` or built JS output
unless a generated file is intentionally part of the app. Add/keep ignore rules
for those directories.

Add repo commands once the Elm app has real tests and builds:

```bash
just frontend-web-test
just frontend-web-build
just frontend-web-review
```

These should run the Elm equivalents of `elm-test`, optimized compilation, and
`elm-review`.

Initial source layout:

```txt
src/
  Main.elm
  Route.elm
  Session.elm
  Theme.elm
  Api/
  Data/
  Page/
  Ui/
tests/
```

## Phase 1: Routing And Access Decisions

### User Stories

- As an unauthenticated visitor, I am sent to login unless first-time setup is
  needed.
- As a first-time operator, I am sent to setup when no admin account exists.
- As an admin, I land on the admin dashboard.
- As a normal user, I land on the diary.
- As an admin, I cannot access food-tracking routes.
- As a normal user, I cannot access admin routes.
- As a visitor, unknown routes fall back to root redirect behavior.

### Tests

Route parsing:

- `"/setup"` parses as `Setup`.
- `"/login"` parses as `Login`.
- `"/admin"` parses as `AdminDashboard`.
- `"/home"` parses as `Diary`.
- `"/logs/abc"` parses as `FoodLogDetail "abc"`.
- `"/search"` parses as `FoodSearch`.
- `"/search?meal_slot=breakfast"` parses as `FoodSearch (Just Breakfast)`.
- `"/foods/abc"` parses as `FoodDetail "abc"`.
- `"/foods/abc?meal_slot=breakfast"` parses as
  `FoodDetail "abc" (Just Breakfast)`.
- `"/foods/custom/new"` parses as `CustomFoodCreate`.
- `"/foods/custom/abc/edit"` parses as `CustomFoodEdit "abc"`.
- `"/meals"` parses as `Meals`.
- `"/meals/new"` parses as `MealCreate`.
- `"/meals/abc"` parses as `MealDetail "abc"`.
- `"/meals/abc/edit"` parses as `MealEdit "abc"`.
- unknown paths parse as `NotFound`.
- `/home?date=YYYY-MM-DD` parses the diary date query separately from the path.

Access decisions:

- Root redirects to setup when `adminExists == False`.
- Root redirects to login when signed out and admin exists.
- Root redirects to admin for an admin identity.
- Root redirects to home for a normal user.
- Protected food routes reject signed-out users.
- Protected food routes reject admins.
- Admin route rejects signed-out users.
- Admin route rejects normal users.
- Setup route redirects away when an admin already exists and the visitor is not
  authenticated.

### Code

Create:

```txt
src/Route.elm
src/Access.elm
```

Keep these functions pure:

```elm
fromUrl : Url -> Route
routeToPath : Route -> String
resolveRoute : Session -> Route -> RouteDecision
```

`RouteDecision` should represent either rendering the requested route or
navigating to another route.

Route state that must survive refresh/back/forward belongs in the URL. In
particular, replace React Router `location.state` with query params:

- diary date: `/home?date=2026-06-04`
- selected meal slot from diary to search: `/search?meal_slot=breakfast`
- selected meal slot from search to food detail:
  `/foods/<id>?meal_slot=breakfast`

## Phase 2: API Contracts

### User Stories

- As the Elm app, I can decode every response the React frontend consumes.
- As the Elm app, I can encode every request the React frontend sends.
- As the Elm app, I preserve decimal quantities as strings.
- As the Elm app, I can distinguish successful empty responses from JSON
  responses.
- As the Elm app, I preserve backend error `status`, `code`, and `message`.

### Tests

Auth:

- Decodes bootstrap status.
- Decodes login session with identity and profile.
- Decodes login session with `profile: null`.
- Encodes login request.
- Encodes bootstrap admin request.
- Decodes backend error envelopes.

Admin:

- Decodes user list.
- Encodes create user request.
- Encodes reset password request.

Foods:

- Decodes search response.
- Decodes category suggestions.
- Decodes product detail with nutrients, servings, and allowed units.
- Decodes nutrient list.
- Decodes unit list.
- Encodes create custom food request.
- Encodes update custom food request.

Logs:

- Decodes log response for product item.
- Decodes log response for meal item.
- Decodes log list.
- Decodes summary response.
- Encodes create log request.
- Encodes update log request with omitted fields.
- Encodes update log request with explicit `meal_slot: null`.

Meals:

- Decodes meal response.
- Decodes meal list.
- Decodes meal nutrition response.
- Encodes create meal request.
- Encodes update meal request.

### Code

Create data modules:

```txt
src/Data/Auth.elm
src/Data/User.elm
src/Data/Quantity.elm
src/Data/ItemRef.elm
src/Data/Food.elm
src/Data/FoodLog.elm
src/Data/Meal.elm
src/Data/Nutrient.elm
src/Data/Unit.elm
```

Create API modules:

```txt
src/Api/Client.elm
src/Api/Auth.elm
src/Api/Admin.elm
src/Api/Foods.elm
src/Api/Logs.elm
src/Api/Meals.elm
```

`Api.Client` should centralize:

- JSON request construction
- JSON response expectations
- `204` handling
- credentials/cookie behavior
- backend error envelope decoding
- error-to-display-string helpers
- `401` detection for global sign-out

Use a custom API error type instead of plain `Http.Error` at page boundaries:

```elm
type ApiError
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Int String String
    | BadBody String
```

`BadStatus status code message` should preserve the backend error envelope that
the React client currently exposes through `ApiError`. Implement this with
`Http.expectStringResponse` so non-2xx response bodies can be decoded before
they become display errors.

If backend and frontend run on different origins during development, use
`Http.riskyRequest` only for cookie-bearing cross-origin requests. Prefer normal
same-origin `Http.request` when the Elm app is served behind the same origin or
a dev proxy.

## Phase 3: Session And Auth Pages

### User Stories

- As a visitor, I see loading while session and bootstrap status load.
- As a user, I can log in with username and password.
- As a user, I see validation errors for missing login fields.
- As a user, I can log out and become signed out.
- As a first-time operator, I can create the admin account.
- As the app, a `401` clears session and navigates to login.

### Tests

Session:

- Initial session is loading.
- Bootstrap success stores identity, profile, and admin status.
- Session failure clears identity but still records bootstrap status.
- Login success stores identity and profile.
- Logout success clears identity and profile.
- Unauthorized clears identity and profile.

Login page:

- Empty username is rejected.
- Empty password is rejected.
- Username is trimmed in the login request.
- Submit sets submitting state.
- Login failure stores error and clears submitting state.
- Login success produces root navigation intent.

Setup page:

- Empty username is rejected.
- Password shorter than 8 characters is rejected.
- Submit sets submitting state.
- Create admin success stores admin session and navigates to admin.
- Create admin failure stores error and clears submitting state.

### Code

Create:

```txt
src/Session.elm
src/Page/Login.elm
src/Page/BootstrapAdminSetup.elm
```

Useful pure helpers:

```elm
validateLogin : LoginForm -> Result ValidationError LoginRequest
validateBootstrapAdmin : SetupForm -> Result ValidationError BootstrapAdminRequest
applyAuthResult : Result ApiError LoginSession -> Session -> Session
```

## Phase 4: Admin Dashboard

### User Stories

- As an admin, I can list users.
- As an admin, I can create a normal user.
- As an admin, I can reset a user password.
- As an admin, I can disable an active user.
- As an admin, I can enable a disabled user.
- As an admin, failed actions show errors without losing existing user data.

### Tests

- Init starts with users loading.
- User load success stores users.
- User load failure stores error.
- Create-user form toggles open and closed.
- Create-user payload trims username and display name.
- Create-user success clears the form and requests user reload.
- Create-user failure preserves the form and existing user list.
- Reset-password form opens for the selected user.
- Reset-password success clears reset form.
- Reset-password failure preserves reset form.
- Disable success requests user reload.
- Enable success requests user reload.
- Disable/enable failure preserves existing users and stores error.

### Code

Create:

```txt
src/Page/AdminDashboard.elm
```

Useful pure helpers:

```elm
createUserPayload : Model -> Result ValidationError CreateUserRequest
resetPasswordPayload : Model -> Result ValidationError ResetPasswordRequest
```

## Phase 5: Diary

### User Stories

- As a user, I can view today's logs.
- As a user, I can view logs for a previous day.
- As a user, I cannot navigate beyond today.
- As a user, I can view logs grouped by meal slot.
- As a user, I can view daily calories and macros.
- As a user, I can toggle macro display between grams and percent.
- As a user, I see product and meal names for logged items.
- As a user, failed diary loading shows an error.
- As a user, selecting add food from a meal slot preserves that slot.
- As a user, I can open a log for editing.

### Tests

Initialization:

- Valid `date` query param becomes the current date.
- Invalid `date` query param falls back to today.
- Missing `date` query param falls back to today.

Date navigation:

- Previous day decrements selected date.
- Next day increments selected date.
- Next day does nothing when selected date is today.

Loading:

- Load started marks diary data as loading.
- Load success stores logs and summary.
- Load failure stores an error.
- Name lookup success merges item names.
- Name lookup failure uses an unknown item fallback.

Derived behavior:

- Logs are grouped into breakfast, lunch, dinner, snack, and other.
- Slot calories are summed from nutrient snapshots.
- Daily calories come from summary `ENERGY_KCAL`.
- Macro totals calculate grams from snapshots.
- Macro percentages calculate from protein/carbs/fat using 4/4/9 kcal factors.
- Macro mode toggles from grams to percent and back.

Navigation intents:

- Add-food action produces navigation to `/search` with the selected meal slot.
- Log row click produces navigation to `/logs/:id`.
- Meals menu action produces navigation to `/meals`.

### Code

Create:

```txt
src/Page/Diary.elm
src/Data/LocalDate.elm
src/Data/Nutrition.elm
```

Useful pure helpers:

```elm
groupLogs : List FoodLog -> GroupedLogs
slotCalories : MealSlot -> List FoodLog -> Float
macroTotals : List FoodLog -> MacroTotals
summaryValue : NutrientCode -> List SummaryEntry -> Maybe NutrientAmount
```

The current React page resolves names after loading logs and summary. Keep that
flow explicit: log/summary success should produce a command to resolve unique
product and meal names.

Represent local diary days deliberately. Elm core has `Time.Posix`, but no
first-class civil `Date`. Either use a small validated `YYYY-MM-DD` wrapper in
`Data.LocalDate`, or add a local-date package. Do not spread raw date string
parsing through page modules.

## Phase 6: Food Search

### User Stories

- As a user, I can type a query and search foods.
- As a user, empty query clears results and does not search.
- As a user, stale responses do not overwrite newer results.
- As a user, I can choose a result and navigate to food detail.
- As a user, I can create a custom food when no result fits.
- As a user, meal slot context survives from diary to food detail.

### Tests

- Empty query clears results, loading, and error.
- Non-empty query increments search token.
- Search started sets loading.
- Matching search result stores items and clears loading.
- Stale search result is ignored.
- Search failure stores error and clears results.
- Search failure from stale token is ignored.
- Select result navigates to food detail with meal slot query context.
- Create custom food navigates to custom food create.
- Numeric query marks barcode visibility for matching rows.

### Code

Create:

```txt
src/Page/FoodSearch.elm
```

Use a request token:

```elm
type alias Model =
    { query : String
    , searchToken : Int
    , results : Loadable ApiError (List SearchResult)
    , mealSlot : Maybe MealSlot
    }
```

Use `Process.sleep 300` for debounce. Elm cannot cancel a sleeping command, so
the request token is mandatory; stale search responses must be ignored in
`update`.

## Phase 7: Food Detail And Product Logging

### User Stories

- As a user, I can load food details.
- As a user, I can load available units.
- As a user, default log quantity and unit come from the food when present.
- As a user, missing defaults fall back to `1 g`.
- As a user, I can log a product with quantity, unit, meal slot, and notes.
- As a user, logging uses the current local timestamp.
- As a user, custom foods expose edit navigation.

### Tests

- Food and units load success initializes the log form.
- Default amount uses `default_quantity`.
- Default unit uses `default_unit`.
- Missing defaults initialize `1 g`.
- Amount is required.
- Create-log payload uses `item.type = "product"`.
- Selected meal slot is included.
- No meal slot is omitted.
- Blank notes become `null`.
- Custom food source `USER` exposes edit path.
- Global food sources do not expose edit path.
- Log success navigates home.
- Log failure keeps form state and stores error.

### Code

Create:

```txt
src/Page/FoodDetail.elm
src/Page/FoodLogForm.elm
```

Useful pure helpers:

```elm
initLogFormFromFood : Maybe MealSlot -> ProductDetail -> FoodLogForm
createProductLogRequest : LocalIsoString -> ProductId -> FoodLogForm -> Result ValidationError CreateLogRequest
customFoodEditRoute : ProductDetail -> Maybe Route
```

Use a browser port for local timestamp creation so log requests exactly match
the current React `localISOString()` helper, including the timezone offset.
This is required for product logging and meal logging.

## Phase 8: Food Log Detail/Edit/Delete

### User Stories

- As a user, I can view a logged item.
- As a user, I can edit quantity, unit, meal slot, and notes.
- As a user, I cannot swap the logged food or meal in the current scope.
- As a user, I can delete a log.
- As a user, product logs resolve product details.
- As a user, meal logs resolve meal names.

### Tests

- Load-log success initializes the edit form.
- Product log requests product name/detail.
- Meal log requests meal name.
- Update payload includes quantity, meal slot, and notes.
- `__none__` or equivalent no-slot value encodes as `meal_slot: null`.
- Blank notes encode as `null`.
- Update success replaces the current log.
- Update failure preserves current log and form state.
- Delete success navigates home.
- Delete failure keeps page open and stores error.

### Code

Create:

```txt
src/Page/FoodLogDetail.elm
```

Reuse:

```txt
src/Page/FoodLogForm.elm
```

Do not add timestamp editing or item swapping. The current React frontend
intentionally leaves those out of scope.

## Phase 9: Custom Food Create/Edit

### User Stories

- As a user, I can create a custom food.
- As a user, I can edit my custom food.
- As a user, I can enter nutrients per 100g.
- As a user, I can enter serving mappings.
- As a user, incomplete nutrient rows are ignored.
- As a user, incomplete serving rows are ignored.
- As a user, categories are normalized and deduplicated.
- As a user, name is required.

### Tests

- Empty custom food form has one nutrient row.
- Name is required.
- Categories are trimmed, lowercased, and deduplicated.
- Incomplete nutrient rows are filtered.
- Incomplete serving rows are filtered.
- Create payload maps form fields correctly.
- Empty brand becomes `null`.
- Empty serving size becomes `null`.
- Empty default quantity becomes `null`.
- Edit init maps product detail into form rows.
- Add nutrient row appends a blank row.
- Remove nutrient row removes the selected row but keeps at least one row.
- Add serving row appends a blank row.
- Remove serving row removes the selected row.
- Save success navigates to food detail.
- Save failure preserves form state.

### Code

Create:

```txt
src/Page/CustomFood/Form.elm
src/Page/CustomFood/Create.elm
src/Page/CustomFood/Edit.elm
```

Useful pure helpers:

```elm
emptyForm : FormModel
fromProductDetail : ProductDetail -> FormModel
toCreateFoodRequest : FormModel -> Result ValidationError CreateFoodRequest
parseCategoriesInput : String -> List String
formatCategoriesInput : List String -> String
```

## Phase 10: Meals List

### User Stories

- As a user, I can list my saved meals.
- As a user, I can open a meal.
- As a user, I can start creating a meal.
- As a user, an empty meal list is handled.

### Tests

- Init starts loading meals.
- Load success stores meals.
- Load failure stores error.
- Empty list derives empty state.
- Open meal navigates to meal detail.
- Create meal navigates to meal form.
- Back action navigates home.

### Code

Create:

```txt
src/Page/Meals.elm
```

## Phase 11: Meal Form

### User Stories

- As a user, I can create a meal from product components.
- As a user, I can edit an existing meal.
- As a user, I can search products per component row.
- As a user, stale component search results do not overwrite newer row state.
- As a user, I can add component rows.
- As a user, I can remove component rows.
- As a user, name is required.
- As a user, at least one selected product is required.
- As a user, optional total quantity is included only when present.

### Tests

- New meal form starts with one empty component.
- Edit meal maps components into rows.
- Product names are merged into edit rows.
- Name is required.
- At least one selected product is required.
- Total quantity is omitted when blank.
- Total quantity is included when present.
- Component quantity defaults to `100 g`.
- Create payload includes selected product components only.
- Update payload matches create payload shape.
- Row search query changes only that row.
- Row search token changes only that row.
- Row search started sets row searching.
- Matching row search result stores results for that row.
- Stale row search result is ignored.
- Select product fills product id and name.
- Add component appends an empty row.
- Remove component removes the selected row.
- Save success navigates to meal detail.
- Save failure preserves form state.

### Code

Create:

```txt
src/Page/MealForm.elm
```

Useful pure helpers:

```elm
emptyComponentRow : RowId -> ComponentRow
toMealRequest : Model -> Result ValidationError CreateMealRequest
updateComponent : RowId -> ComponentPatch -> Model -> Model
selectedComponents : List ComponentRow -> List CreateMealComponentRequest
```

Meal components remain product-only to match the current backend and frontend
scope.

## Phase 12: Meal Detail And Meal Logging

### User Stories

- As a user, I can view meal components.
- As a user, component product names are resolved.
- As a user, I can preview nutrients for a chosen amount and unit.
- As a user, invalid amount suppresses nutrient preview.
- As a user, stale nutrient preview responses are ignored.
- As a user, I can log a meal.
- As a user, I can delete a meal after confirmation.
- As a user, I can navigate to edit meal.

### Tests

- Meal load success stores meal.
- Component product ids are extracted uniquely.
- Product name load merges names.
- Unit load stores units.
- Invalid log amount clears nutrient preview.
- Amount change starts a new nutrient preview token.
- Unit change starts a new nutrient preview token.
- Matching nutrient preview response stores nutrients.
- Stale nutrient preview response is ignored.
- Log meal payload uses `item.type = "meal"`.
- Log success navigates home.
- Log failure preserves state and stores error.
- Delete confirmation opens.
- Delete confirmation closes.
- Delete success navigates to meals.
- Delete failure keeps confirmation open and stores error.
- Edit action navigates to meal edit.

### Code

Create:

```txt
src/Page/MealDetail.elm
```

Useful pure helpers:

```elm
uniqueProductIds : Meal -> List ProductId
validPreviewAmount : String -> Maybe Float
createMealLogRequest : LocalIsoString -> MealId -> LogMealForm -> Result ValidationError CreateLogRequest
```

## Phase 13: Shared Pure Helpers

These helpers should be tested before pages depend on them.

### User Stories

- As the app, I can format local dates for backend date-range queries.
- As the app, I can create local ISO timestamps with timezone offsets for log
  requests.
- As the app, I can parse and display nutrient amounts consistently.
- As the app, I can scale food nutrients by serving quantity.
- As the app, I can normalize category input.

### Tests

Date helpers:

- Formats `YYYY-MM-DD`.
- Parses valid `YYYY-MM-DD`.
- Rejects invalid dates.
- Prevents next-day navigation beyond today.
- Produces stable route query strings for diary dates.

Nutrition helpers:

- Invalid amount parses as `0`.
- Negative amount parses as `0`.
- Missing nutrient amount returns `0`.
- Calories read from `ENERGY_KCAL`.
- Macro totals sum protein, carbs, and fat.
- Macro percentages use 4/4/9 kcal factors.
- Grams unit returns amount unchanged.
- Known serving unit converts amount to grams.
- Unknown serving unit returns `Nothing`.
- Nutrient scaling multiplies per-100g nutrients by grams / 100.

Category helpers:

- Categories split by comma.
- Categories are trimmed.
- Categories are lowercased.
- Duplicate categories are removed.
- Empty categories are ignored.

### Code

Create:

```txt
src/Data/LocalDate.elm
src/Data/Nutrition.elm
```

Port behavior from:

- `frontend/src/lib/time.ts`
- `frontend/src/lib/nutrition.ts`

## Phase 14: Theme And Browser Ports

### User Stories

- As a user, my theme choice persists.
- As a user, the app can use my system color preference on first load.
- As a user, toggling theme updates app state and browser storage.
- As the app, product and meal logging can request a local ISO timestamp with
  timezone offset from the browser.

### Tests

- Initial theme uses stored value when present.
- Initial theme falls back to system preference.
- Toggle changes dark to light.
- Toggle changes light to dark.
- Toggle produces a save-theme intent.
- Local timestamp responses are routed back to the pending log workflow.

### Code

Create:

```txt
src/Theme.elm
```

Use flags/ports for browser-only behavior:

```elm
port saveTheme : String -> Cmd msg
port applyTheme : String -> Cmd msg
port requestLocalIsoTimestamp : () -> Cmd msg
port gotLocalIsoTimestamp : (String -> msg) -> Sub msg
```

Theme is lower priority than feature workflows. Local timestamp ports are not:
they are needed before implementing product logging or meal logging.

## Phase 15: Elm UI Layer

Visual parity with React/Mantine is not a goal, but the Elm app should have a
coherent `elm-ui` design system from the start. Build only enough UI structure
to exercise the workflows, but keep all layout, spacing, color, and typography
inside Elm UI helpers rather than Tailwind/CSS classes.

Create:

```txt
src/Ui/Button.elm
src/Ui/Input.elm
src/Ui/Select.elm
src/Ui/PageHeader.elm
src/Ui/ErrorBanner.elm
src/Ui/EmptyState.elm
src/Ui/Loading.elm
src/Ui/Table.elm
```

These modules should expose `Element msg` building blocks. `Main.view` is
responsible for wrapping page `Element Msg` values with `Element.layout`.

Tests should remain focused on pure behavior. Only add view tests when a view
contains non-trivial branching that is not already covered by pure helpers.

## Recommended Build Order

Use vertical slices. Each slice should end with passing tests and a manually
usable route.

1. Elm app skeleton and test harness.
2. API data contracts and JSON tests.
3. Routing and route guard decisions.
4. Session bootstrap, login, logout, and first-time setup.
5. Admin dashboard.
6. Diary read-only.
7. Food search.
8. Food detail and product logging.
9. Food log edit/delete.
10. Custom food create/edit.
11. Meals list.
12. Meal create/edit.
13. Meal detail, nutrient preview, log, and delete.
14. Theme persistence.
15. Elm UI cleanup.

## Definition Of Feature Parity

The Elm frontend is feature-complete when these route workflows match the
current React app:

- `/setup`: create first admin and route to admin dashboard.
- `/login`: log in and route according to identity role.
- `/admin`: list/create users, reset passwords, enable/disable users, logout.
- `/home`: selected-day diary, previous/next day, grouped logs, summaries,
  macro toggle, add-food by meal slot, open log detail, meals navigation,
  logout, theme toggle.
- `/search`: debounced food search, empty/no-result states, custom-food create
  navigation, preserve meal slot to food detail.
- `/foods/:id`: food detail, nutrient/serving display, log product, custom-food
  edit navigation when source is `USER`.
- `/logs/:id`: view/edit quantity/unit/meal slot/notes, delete log.
- `/foods/custom/new`: create custom food.
- `/foods/custom/:id/edit`: edit custom food.
- `/meals`: list meals and navigate to create/detail.
- `/meals/new`: create meal with searched product components.
- `/meals/:id`: view components, preview nutrients by amount/unit, log meal,
  edit, delete.
- `/meals/:id/edit`: edit meal.

No frontend import administration, offline support, barcode scanning, analytics
dashboard, password self-service, or export flow is required for parity with the
current browser app.
