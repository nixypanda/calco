# Elm Architecture Plan

This is the parallel document to `REDUCER_ARCHITECTURE_PLAN.md`. It describes
what the same frontend would look like written in Elm, section-by-section.

The short version: most of what the React/TS plan invents — `RemoteData`,
`useAsync`, `useAsyncChain`, the URL-is-source-of-truth rule, the page → app
dispatch boundary, the "no `AppEffect` runtime" decision — either exists as
stdlib or as a small, well-known community package in Elm. The Elm Architecture
(TEA) *is* the architecture the React doc was approximating.

The Elm app coexists in `frontend-web/` while the existing React app remains in
`frontend/` as the behavioral reference. This is a rewrite, not an in-place
port. When the Elm app reaches feature parity, the React frontend can be
removed.

Use `mdgriffith/elm-ui` as the UI system. Do not build the Elm app around
Tailwind classes, ad hoc class strings, or a second CSS utility layer. Styling
should live in Elm values and shared `Ui/*` modules.

## Goal

Same goal: page and workflow logic live in pure functions; effects are
explicit; state is scoped to the smallest useful owner; tests target pure
`update` functions.

In Elm this is the default. There is nothing to opt into.

## Architecture Shape

Module layout:

```txt
src/
  Main.elm
  Route.elm
  Session.elm
  Theme.elm
  Api/
    Client.elm
    Auth.elm
    Foods.elm
    Meals.elm
    Logs.elm
    Users.elm
  Data/
    LocalDate.elm
    Food.elm
    FoodLog.elm
    Meal.elm
    Nutrition.elm
    Unit.elm
  Page/
    Diary.elm
    MealDetail.elm
    MealForm.elm
    FoodLogDetail.elm
    AdminDashboard.elm
    CustomFood/
      Form.elm
      Create.elm
      Edit.elm
    FoodSearch.elm
    FoodDetail.elm
    Meals.elm
```

Each page module exports the same five values:

```elm
module Page.Diary exposing (Model, Msg, init, update, view, subscriptions)

import Element exposing (Element)

type alias Model = { ... }
type Msg = ...

init : { ...route params... } -> Session -> ( Model, Cmd Msg )
update : Msg -> Model -> ( Model, Cmd Msg )
view : Model -> Element Msg
subscriptions : Model -> Sub Msg
```

This matches the React doc's "Container / View / state.ts / effects.ts"
split, collapsed into Elm's idiom:

| React/TS | Elm |
|---|---|
| `state.ts` (`init`, `update`, `Model`, `Msg`) | the page module's top half |
| `<Page>View.tsx` | the page module's `view` function returning `Element Msg` |
| `<Page>.tsx` container | the parent's `update` branching into the page's `update` and rendering its `view` |
| `effects.ts` | unused — effects are `Cmd`s returned from `update` |

Default to a single module per page. Split into multiple modules
(`Page.Diary.View`, `Page.Diary.Update`) only when a single file becomes
painful — same rule as the React doc.

## Reducer Style

There is one shape, and it is the canonical TEA shape:

```elm
update : Msg -> Model -> ( Model, Cmd Msg )
```

The reducer is `update`. Effects are `Cmd Msg` values. The Elm runtime
executes them and dispatches their results as `Msg`s back into `update`. This
is the `UpdateResult<Model, Effect>` shape the React doc considered and
deferred — in Elm it is the only option and there is nothing to build.

There is no analogue of "evolve to effect-returning reducer" because there
is no other style to evolve from.

## Async Resources

### Loadable State

Use either `krisajenkins/remotedata` from packages.elm-lang.org or a local
equivalent. The important shape is the state machine:

```elm
type Loadable error value
    = NotAsked
    | Loading
    | Failure error
    | Success value

type alias Model =
    { log : Loadable ApiError FoodLog
    , food : Loadable ApiError Food
    , units : Loadable ApiError (List Unit)
    }
```

This is the same discriminated union as the React doc's
`RemoteData<T, ApiError>`, with `NotAsked | Loading | Failure error | Success
value` constructors. `krisajenkins/remotedata` is fine if it fits, but a local
type lets the app use its own `ApiError` directly.

### Loading data

The React doc's `useAsync` is replaced by `Http.get` (or `Http.post`)
returning a `Cmd Msg`:

```elm
loadLog : Int -> Cmd Msg
loadLog id =
    Api.Logs.get id GotLog
```

`update` then handles the result:

```elm
GotLog result ->
    ( { model | log = Loadable.fromResult result }, Cmd.none )
```

No hook to write, no ref dance, no stale-closure trap. The runtime is the
runtime.

### Chained loads

The React doc's `useAsyncChain` (with reset semantics) is replaced by
dispatching the dependent request from the parent's success branch:

```elm
GotLog (Ok log) ->
    ( { model | log = Success log, food = Loading }
    , Api.Foods.get log.foodId GotFood
    )

GotLog (Err err) ->
    -- parent failed; descendants reset
    ( { model | log = Failure err, food = NotAsked, units = NotAsked }
    , Cmd.none
    )

GotFood (Ok food) ->
    ( { model | food = Success food, units = Loading }
    , Api.Foods.units food.unitIds GotUnits
    )
```

Reset semantics are explicit in `update`, not hidden in a hook. When the
parent transitions, you write exactly what the descendants should do — and
the compiler enforces that every `Msg` variant is handled.

For consistency-critical workflows, define a single ADT instead of several
chained loadable fields:

```elm
type LoadState
    = LoadingLog
    | LoadedLog FoodLog
    | LoadedFood FoodLog Food
    | LoadedAll FoodLog Food (List Unit)
    | Failed ApiError Stage

type Stage = LogStage | FoodStage | UnitsStage
```

Pattern-matching keeps the model consistent across stages.

### API errors

The backend returns useful error envelopes. Preserve them instead of collapsing
all non-2xx responses into plain `Http.Error`:

```elm
type ApiError
    = BadUrl String
    | Timeout
    | NetworkError
    | BadStatus Int String String
    | BadBody String
```

`BadStatus status code message` matches the current React client's
`ApiError(status, code, message)`. Implement this in `Api.Client` with
`Http.expectStringResponse`, decoding success bodies and backend error bodies in
one place.

The 401 case remains ordinary data:

```elm
GotLog (Err (BadStatus 401 _ _)) ->
    ( { model | session = SignedOut }
    , Browser.Navigation.replaceUrl model.key "/login"
    )
```

## Router State

`Browser.application` owns URL handling. Every URL change — link click,
back button, forward button, programmatic navigation — dispatches an
`UrlChanged Url` message:

```elm
main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }
```

The React doc's "URL is source of truth, model mirrors it" convention is
enforced by the runtime, not by team discipline. There is no other path
into the page.

```elm
UrlChanged url ->
    let route = Route.fromUrl url
    in changeRouteTo route model

LinkClicked (Browser.Internal url) ->
    ( model, Browser.Navigation.pushUrl model.key (Url.toString url) )

LinkClicked (Browser.External href) ->
    ( model, Browser.Navigation.load href )
```

Route state that must survive refresh/back/forward belongs in the URL. Replace
React Router `location.state` with query params:

- diary date: `/home?date=2026-06-04`
- diary-selected meal slot to search: `/search?meal_slot=breakfast`
- search-selected meal slot to food detail: `/foods/<id>?meal_slot=breakfast`

Diary's prev/next is a pure helper plus an Elm UI link that navigates to the new
URL:

```elm
-- in Data.LocalDate
next : LocalDate -> LocalDate
next d = ...

prev : LocalDate -> LocalDate
prev d = ...

-- in Page.Diary.view
link []
    { url = Route.diary (LocalDate.next model.date) |> Route.toString
    , label = text "Next"
    }
```

No `date/next` message in the reducer. No split-brain. Compiler-enforced.

## Global State

There is no separate "app reducer". There is one `Main.update`, one `Main.Model`,
and pages are nested inside it:

```elm
type alias Model =
    { key : Browser.Navigation.Key
    , route : Route
    , session : Session
    , darkMode : Bool
    , bootstrap : Loadable ApiError BootstrapStatus
    , page : PageModel
    }

type PageModel
    = DiaryPage Page.Diary.Model
    | MealDetailPage Page.MealDetail.Model
    | MealFormPage Page.MealForm.Model
    | FoodLogDetailPage Page.FoodLogDetail.Model
    | AdminDashboardPage Page.AdminDashboard.Model
    | ...
    | NotFound

type Msg
    = UrlChanged Url
    | LinkClicked Browser.UrlRequest
    | SessionLoaded (Result ApiError Session)
    | LogoutClicked
    | ThemeToggled
    | GotPage PageMsg

type PageMsg
    = DiaryMsg Page.Diary.Msg
    | MealDetailMsg Page.MealDetail.Msg
    | ...
```

Page messages bubble up via `Cmd.map`:

```elm
GotPage (DiaryMsg subMsg) ->
    case model.page of
        DiaryPage subModel ->
            let
                ( newSubModel, subCmd ) =
                    Page.Diary.update subMsg subModel
            in
            ( { model | page = DiaryPage newSubModel }
            , Cmd.map (GotPage << DiaryMsg) subCmd
            )

        _ ->
            ( model, Cmd.none )
```

### Page → app boundary

When a page needs to signal "session expired" or "navigate elsewhere" to
the global layer, it returns a third value from its `update`:

```elm
-- in Page.Diary
type OutMsg
    = NoOp
    | SessionExpired
    | NavigateTo Route

update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
```

`Main.update` then acts on the `OutMsg`:

```elm
GotPage (DiaryMsg subMsg) ->
    let
        ( newSubModel, subCmd, outMsg ) =
            Page.Diary.update subMsg subModel

        ( newModel, extraCmd ) =
            applyOutMsg outMsg { model | page = DiaryPage newSubModel }
    in
    ( newModel
    , Cmd.batch [ Cmd.map (GotPage << DiaryMsg) subCmd, extraCmd ]
    )

applyOutMsg : Page.Diary.OutMsg -> Model -> ( Model, Cmd Msg )
applyOutMsg out model =
    case out of
        Page.Diary.SessionExpired ->
            ( { model | session = SignedOut }
            , Browser.Navigation.replaceUrl model.key "/login"
            )

        Page.Diary.NavigateTo route ->
            ( model, Browser.Navigation.pushUrl model.key (Route.toString route) )

        Page.Diary.NoOp ->
            ( model, Cmd.none )
```

Same idea as the React doc's `appDispatch` boundary, but as data flowing
upward through return values rather than as a context dispatch.

### Theme / `localStorage` / DOM

Persisted theme uses flags and ports. The same browser interop module should
also provide local ISO timestamps with timezone offsets for log creation,
matching the current React `localISOString()` behavior:

```elm
port saveTheme : String -> Cmd msg
port applyTheme : String -> Cmd msg
port requestLocalIsoTimestamp : () -> Cmd msg
port gotLocalIsoTimestamp : (String -> msg) -> Sub msg
```

```elm
ThemeToggled ->
    let darkMode = not model.darkMode
    in ( { model | darkMode = darkMode }, saveTheme darkMode )
```

The JS shim around `localStorage`, system color preference, DOM theme
application, and timestamp creation lives outside the Elm app.

## What Should Use Reducers

In Elm the answer is "everything that has state." There is no `useState`
escape hatch. A single-input draft is just a field on the page's `Model`.

The React doc's "is this useState-worthy or useReducer-worthy?" question
disappears.

## Page Migration Plan

This is not a migration — it is a rewrite. Realistic order, simplest to
hardest:

### 0. Foundations

- `Api/Client.elm` with `Http.get`/`post`/`put`/`delete` wrappers that
  handle the base URL, cookies, `204`, JSON decoding, and backend error
  envelopes uniformly.
- `Route.elm` with `fromUrl : Url -> Route` and `toString : Route -> String`.
- `Session.elm` with `Session = SignedIn Identity Profile | SignedOut`.
- `Data/*` decoders for every server shape.
- `Data/LocalDate.elm` as either a validated `YYYY-MM-DD` wrapper or a thin
  wrapper around a local-date package. Elm core has `Time.Posix`, not a civil
  `Date` type.
- `Interop.elm`/ports for theme and local timestamp requests.
- repo commands for `frontend-web` test/build/review in the `justfile`.

### 1. Main.elm shell

- `Browser.application` boot.
- `init` calls `Api.Auth.session` and stores `Loading` until it resolves.
- URL routing dispatches into a `NotFound` page initially.
- Layout (header, sidebar) renders even before pages are wired.

### 2. Auth and theme

- `SessionLoaded`, `LogoutClicked`, `ThemeToggled` handled in `Main.update`.
- Login/setup pages (simple forms).
- Theme persisted via a port.

### 3. Pages, simplest first

1. `Page.FoodSearch` — query, results list, debounce via `Time.every` or
   `Process.sleep` + `Task.perform`.
2. `Page.FoodDetail` — single fetch, display.
3. `Page.Meals` — list fetch, display.
4. `Page.Diary` — date routing, multiple fetches, macro mode toggle.
5. `Page.MealDetail` — chained loads, delete confirmation, log-meal flow.
6. `Page.FoodLogDetail` — load + edit + save + delete.
7. `Page.MealForm` — form-heavy, validation, edit/create modes.
8. `Page.AdminDashboard` — list + create-user + reset-password.
9. `Page.CustomFood.*` — form + create/edit pages.

### 4. UI layer

Replace Mantine with `mdgriffith/elm-ui` and a small `Ui/*` vocabulary:
buttons, inputs, selects, page headers, banners, empty/loading states, tables,
and modal/confirmation patterns. This is the largest single cost of the
rewrite, but it keeps styling easy to manage inside Elm. Avoid Tailwind and
plain class-based layout in the Elm app.

## Testing Strategy

- `elm-test` runs pure `update` tests directly. No mocks. No mounting. No
  router context. No auth provider.
- One test per `Msg` variant that changes behavior.
- One test per important guarded transition.
- For HTTP-heavy pages, test the `update` response to each loadable-state variant
  separately.
- For `view`-level assertions (when needed), use `elm-program-test` for
  small integration tests — it drives the whole TEA loop in a test harness
  without a real DOM.

The React doc's "delete duplicated component-test assertions" guidance is
irrelevant: there are no component tests to dedupe.

## Stop Conditions

Inverted from the React doc — the question is not "have we migrated this
page yet?" but "is this page coherent?":

- `update` covers all `Msg` variants (compiler-enforced).
- `Model` does not have invalid states representable (compiler-enforced via
  custom types).
- HTTP errors flow through the app's loadable/API-error types to the view.
- Cross-cutting messages flow upward via `OutMsg`.
- Tests cover meaningful state transitions.

## What Elm Gives You That The React Plan Has To Build

| Concern | React/TS doc | Elm |
|---|---|---|
| Pure reducer | `useReducer` + discipline | `update` (only option) |
| Effects as data | `useAsync` hook + ref dance | `Cmd Msg` (stdlib) |
| Effect runner | `useAsync` internals | Elm runtime |
| Chained loads | `useAsyncChain` + reset semantics | dispatch from `update` (explicit) |
| `RemoteData<T, E>` | hand-written primitive | `krisajenkins/remotedata` or a tiny local `Loadable` type |
| Typed API errors | `ApiError` class + event side effect | `ApiError` ADT decoded centrally in `Api.Client` |
| URL is source of truth | convention + one `useEffect` mirror | `Browser.application` (enforced) |
| Page → app boundary | `appDispatch` from context | `OutMsg` return value |
| App-level reducer | new shape + provider | top-level `update`, pages nested |
| App-level effect runtime | "no — use focused `useEffect`s" | `Cmd Msg` (same runtime as pages) |
| Discriminated union exhaustiveness | manual `never` default | compiler-enforced |
| `useState` vs. `useReducer` decision | architectural debate | does not exist; everything is `Model` |

## What You Give Up

Honest list:

- **Mantine and the React UI ecosystem.** elm-ui is principled but visually
  spartan; rebuilding the component vocabulary is real work.
- **npm.** Some packages have Elm equivalents; many don't. Anything
  imperative (charting, autocomplete with virtual scrolling, rich text)
  requires writing JS shims behind ports.
- **Active language development.** Elm 0.19.x has been effectively frozen
  for years. Pragmatic improvements people want are unlikely to land.
- **Hiring / contributor pool.** Effectively zero outside FP enthusiasts.
  For a solo project this does not matter; if collaboration is ever a
  possibility, it does.
- **Tooling.** elm-lsp and elm-format are good. elm-review is excellent.
  But the IDE experience is less rich than modern TS + Biome + Vitest.
- **`async`/`await`.** Elm uses `Cmd` for effects and `Task` for
  composable promises. Different idiom; takes adjustment.
- **CSS-in-JS / Tailwind.** The Elm app intentionally does not use them.
  `elm-ui` becomes the styling and layout system.

## What You Gain

- **No state-shape bugs.** `Maybe`, `Result`, custom types make invalid
  states unrepresentable.
- **No runtime exceptions in app code.** Errors are `Result a Error` or
  variants in a custom type.
- **Refactors are mechanical.** Compiler walks you through every site that
  needs an update.
- **Tests run in milliseconds.** No JSDOM, no mocks, no providers.
- **One mental model.** Every page looks the same: `Model`, `Msg`,
  `init`, `update`, `view`, `subscriptions`.
- **Smaller bundles.** Elm's tree-shaker is aggressive and the output is
  small.
- **No async hook to debug, no router rule to enforce, no `AppEffect`
  debate.** The doc you're reading is shorter than the React doc because most
  of its content does not need to exist.

## Should You Do This?

The question is not technical — Elm is unambiguously a better fit for the
exact architecture goals stated in `REDUCER_ARCHITECTURE_PLAN.md`. The
question is whether the ecosystem and language-velocity costs are
acceptable for *this* project.

Reasonable framings:

- **Personal app, primary goal is a principled architecture and an
  enjoyable codebase:** Elm is the right choice.
- **Personal app, primary goal is shipping features fast and reusing UI
  libraries you already know:** stay in TS. Implement the React plan.
- **Want to learn TEA deeply without committing:** port one page
  (suggest `Page.MealForm` — most workflow-shaped) to Elm as a side
  experiment. You'll learn whether the cost feels acceptable in two
  weekends.
