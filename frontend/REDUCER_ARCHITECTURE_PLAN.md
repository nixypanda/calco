# Reducer Architecture Plan

## Goal

Move page and workflow logic into testable pure functions without turning the
frontend into a full Elm-style framework.

The target is:

- Views render from a model and dispatch messages.
- Reducers/update functions are pure and easy to unit test.
- Effects are explicit and isolated from render code.
- State remains scoped to the smallest useful owner.

This is intentionally not a "single app-wide reducer for everything" plan.

## Architecture Shape

Default to a **single page file** with named exports for `init`, `update`,
`Model`, and `Msg`. The reducer should be testable by importing `update` from
the page file directly — no extra files are required for that.

Split into separate files only when the single file becomes painful to read, or
when tests want to import `update` without dragging in React/Router context.
When a page does warrant the full split, use:

```txt
src/pages/<page>/<Page>.tsx
src/pages/<page>/<Page>View.tsx
src/pages/<page>/state.ts
src/pages/<page>/effects.ts
```

The Diary page is the clearest candidate for the full split because it already
has a reducer inline and is the longest page. Other pages should start as a
single file with internal sections and only graduate to the multi-file layout
when keeping them flat adds real friction.

### Container

The page container owns React wiring:

- `useReducer` for page state
- `useAsync` / `useAsyncChain` calls for API loads (see "Async Resources")
- `useEffect` for URL mirroring and other narrow side effects
- router hooks such as `useNavigate` and `useSearchParams`
- passing `model` and `dispatch` into the view

The container should avoid business logic.

### View

The view receives all state as props:

```ts
type Props = {
  model: PageModel;
  dispatch: Dispatch<PageMsg>;
};
```

The view may:

- render derived display values
- dispatch user intent messages
- contain simple presentational components

The view should not:

- call APIs
- read or write `localStorage`
- mutate DOM/global theme state
- decide loading/error transitions
- contain workflow branching that belongs in `state.ts`

### State

`state.ts` owns pure logic:

- `PageModel`
- `PageMsg`
- `init`
- `update`
- pure helper functions for transitions

Tests should target this file heavily.

### Effects

Most pages will not need an `effects.ts` file. API orchestration moves into
`useAsync(Chain)` calls in the container (see "Async Resources"); navigation
is just `navigate(...)` at the dispatch site; `localStorage` and DOM theme
application live in app-level state after §2 of the migration plan.

Add `effects.ts` only when a page has a non-trivial, non-API, non-router
side effect that genuinely benefits from being isolated and tested in
isolation. When it does exist, it owns impure adapters such as:

- item-name lookup orchestration
- page-local `localStorage` reads/writes
- any DOM/imperative integration

Effects should return messages back to the reducer rather than directly
changing page state.

## Reducer Style

For API-driven flows, prefer the `RemoteData` + `useAsync` pattern in the
"Async Resources" section below over the `UpdateResult` evolution shown here.
The escape hatch is kept for completeness; it should not be the first reach
for any new page.

Start with simple React `useReducer`:

```ts
const [model, dispatch] = useReducer(update, initialModel);
```

For API lifecycle, the first acceptable step is:

```ts
dispatch({ type: "loadStarted" });
const data = await loadPageData();
dispatch({ type: "loadSucceeded", data });
```

For pages that benefit from a fuller flow, evolve to:

```ts
type UpdateResult<Model, Effect> = {
  model: Model;
  effects: Effect[];
};
```

In that version, the reducer decides which effects should happen, and a runner
executes them outside the reducer.

Do this only when it makes the page simpler. Do not force command/effect results
onto trivial pages. For the common case — "this page loads some data from an
API" — prefer the `RemoteData` / `useAsync` pattern described in the next
section over evolving the reducer to return effects.

## Async Resources

Every page that loads data from an API has the same shape today:

```ts
const [loading, setLoading] = useState(true);
const [error, setError] = useState<string | null>(null);
const [data, setData] = useState<T | null>(null);
```

This lets invalid states (`loading=true && data=X`, or `data=null` after a
successful load) be representable, and it forces every test to mount the
component and mock the API. Replace it with a small shared primitive.

### `ApiError`

Before `RemoteData` lands, API errors need a typed shape so cross-cutting
handling (especially 401 → `auth/unauthorized`) can inspect status codes
rather than parsing strings.

```ts
// src/api/error.ts
export type ApiError =
  | { kind: "http"; status: number; message: string; body?: unknown }
  | { kind: "network"; message: string }
  | { kind: "parse"; message: string };

export const isUnauthorized = (e: ApiError): boolean =>
  e.kind === "http" && e.status === 401;

export const toApiError = (err: unknown): ApiError => {
  // map fetch/parse/network failures to the shape above; throw-time helper
  // used by the API client wrappers and by useAsync's catch.
};
```

The API client functions in `src/api/*` should throw `ApiError` from a
single wrapper (e.g., around `fetch`). Doing this is a prerequisite for
landing `RemoteData` — without it, the failure branch carries opaque
strings and the page → app dispatch boundary can't tell 401 from anything
else.

### `RemoteData<T>`

```ts
// src/lib/remoteData.ts
import type { ApiError } from "@/api/error";

export type RemoteData<T, E = ApiError> =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "success"; data: T }
  | { status: "failure"; error: E };

export const idle    = <T, E = ApiError>(): RemoteData<T, E> => ({ status: "idle" });
export const loading = <T, E = ApiError>(): RemoteData<T, E> => ({ status: "loading" });
export const success = <T, E = ApiError>(data: T): RemoteData<T, E> => ({ status: "success", data });
export const failure = <T, E = ApiError>(error: E): RemoteData<T, E> => ({ status: "failure", error });
```

Use `RemoteData<T>` for any model field whose value is loaded from an API.
Discriminated union means no `data!` in the view and no `loading && error`
triplet bugs. `E` defaults to `ApiError` so the typed error survives all the
way to the View and the cross-cutting handlers.

### `useAsync`

Implementation must avoid the stale-closure / infinite-loop trap by keeping
the latest `run` and `onChange` in refs. Callers can then pass inline
closures without `useCallback` ceremony; the hook re-runs only when `deps`
change.

```ts
// src/hooks/useAsync.ts
import { useEffect, useRef } from "react";
import { toApiError } from "@/api/error";
import type { RemoteData } from "@/lib/remoteData";

export function useAsync<T>(
  run: () => Promise<T>,
  deps: React.DependencyList,
  onChange: (r: RemoteData<T>) => void,
): void {
  const runRef = useRef(run);
  const onChangeRef = useRef(onChange);
  useEffect(() => {
    runRef.current = run;
    onChangeRef.current = onChange;
  });

  useEffect(() => {
    let cancelled = false;
    onChangeRef.current({ status: "loading" });
    runRef.current().then(
      (data) => { if (!cancelled) onChangeRef.current({ status: "success", data }); },
      (err)  => { if (!cancelled) onChangeRef.current({ status: "failure", error: toApiError(err) }); },
    );
    return () => { cancelled = true; };
    // deps are the inputs whose change should re-trigger the load; the hook
    // intentionally does not re-run when `run` or `onChange` change identity.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}
```

Caveat for callers: `deps` are the inputs whose change should re-trigger
the load. Anything `run` semantically depends on must appear in `deps` —
the lint rule cannot help here because the hook deliberately ignores
`run`'s identity.

`useAsync` is the only impure piece. It is tested once and reused. Open
question to settle when this lands: whether `run` should also receive an
`AbortSignal` for real network cancellation, or stay with the "ignore late
result" pattern shown here. Default to the simpler version unless a page
needs real cancellation.

### `useAsyncChain` (dependent loads)

```ts
// src/hooks/useAsync.ts
export function useAsyncChain<T, U>(
  source: RemoteData<T>,
  identity: (t: T) => unknown,                  // what counts as the same source
  run: (t: T) => Promise<U>,
  onChange: (r: RemoteData<U>) => void,
): void;
```

Reset semantics — this is the rule that prevents mismatched data in the
model:

- When `source.status !== "success"`, the hook dispatches `loading` (or
  `idle` on initial mount) for the downstream and does **not** fetch.
- When `source.status === "success"` and `identity(source.data)` changes,
  the hook dispatches `loading` for the downstream and starts the fetch.
- When `source` stays at the same `identity`, the hook is a no-op.

In other words: when a parent leaves `success` or its identity changes,
its descendants reset. The downstream `RemoteData` never carries data
derived from a stale parent.

For workflows where consistency across several dependent steps matters
more than the independence of each `RemoteData` (e.g., MealDetail's
load → nutrition → display), a compound resource type
(`Pipeline<T1, T2, T3>`) may be preferable to three chained
`RemoteData`s. Leave that as a per-page judgment call.

### Usage

Pure half lives in the reducer:

```ts
type Model = {
  log:   RemoteData<FoodLog>;
  food:  RemoteData<Food>;
  units: RemoteData<Unit[]>;
};

type Msg =
  | { type: "logResult";   r: RemoteData<FoodLog> }
  | { type: "foodResult";  r: RemoteData<Food> }
  | { type: "unitsResult"; r: RemoteData<Unit[]> };

const update = (m: Model, msg: Msg): Model => {
  switch (msg.type) {
    case "logResult":   return { ...m, log:   msg.r };
    case "foodResult":  return { ...m, food:  msg.r };
    case "unitsResult": return { ...m, units: msg.r };
  }
};
```

Impure half lives in the container:

```ts
useAsync     (() => getLog(logId), [logId], (r) => dispatch({ type: "logResult",   r }));
useAsyncChain(model.log,  (log)  => log.foodId,    (log)  => getFood(log.foodId),         (r) => dispatch({ type: "foodResult",  r }));
useAsyncChain(model.food, (food) => food.unitIds,  (food) => getUnits(food.unitIds),      (r) => dispatch({ type: "unitsResult", r }));
```

Each leaf transition is a one-line `case` in the reducer. The chaining order
is visible as the literal sequence of calls in the container.

### Relationship to `UpdateResult<Model, Effect>`

`useAsync` is the effect runner. The "evolve to effect-returning reducer"
escape hatch in the Reducer Style section is not needed for API-driven flows
— `RemoteData` + `useAsync(Chain)` keeps reducers pure without inventing a
local effect runtime per page.

## Router State

Pages routinely have state that lives both in the URL (`?date=...`,
`?q=...`, route params) and in the reducer model. Without a rule, the two
drift: browser back button updates the URL but not the model; a date picker
that calls `navigate(...)` bypasses the reducer; `init` defaults to "today"
while the URL says otherwise, producing a flash of wrong data and a double
API call.

**Convention: URL is the source of truth. Model mirrors it.**

Concretely, for any value that appears in the URL:

- `init(params)` reads it from `searchParams` / route params. There is no
  default that disagrees with what the URL would resolve to.
- UI that "changes" the value calls `navigate(...)` (or
  `setSearchParams(...)`). It does **not** dispatch a model message
  directly.
- One `useEffect` in the container watches `searchParams` and dispatches a
  single `urlChanged` (or domain-named) message that updates the mirrored
  field in the model.
- The reducer never writes the URL.
- API calls read from the model, which is the mirrored URL value.

This handles back/forward navigation, shareable links, and external links
into the page uniformly — every change flows URL → model → render.

Values that are *not* in the URL (loading flags, drafts, transient UI
toggles) stay in the model only and follow normal reducer rules.

**Transitions over URL-mirrored values (prev/next/jump-to-today) are pure
helpers in `state.ts`, not reducer messages.** For example, `prevDate(d)`
and `nextDate(d)` are pure functions of a date string. The container uses
them to compute the next URL and calls `navigate(?date=${nextDate(model.date)})`.
The URL → model effect then dispatches `urlChanged`. There is no
`date/previous` or `date/next` reducer message — that would re-introduce
the split-brain the convention exists to prevent.

## Global State

Use a small app-level reducer only for truly global concerns:

- authenticated identity/profile
- admin bootstrap status
- theme preference
- global unauthorized handling

Suggested structure:

```txt
src/app/state.ts          // AppMsg, AppState, appReducer, init — pure
src/app/AppProvider.tsx   // useReducer + useAsync + focused useEffects + context
```

`AppProvider` is the impure layer; pages consume `useAppState()` from its
context. No separate `effects.ts` at the app layer — side effects live as
named `useEffect` blocks inside the provider.

Avoid moving page state into the global reducer. Page state should stay with the
page unless multiple independent routes must coordinate around the same state.

### Page → app dispatch boundary

Pages need to send messages to the app-level reducer for cross-cutting
concerns — most importantly, routing a 401 from an authenticated API call to
`auth/unauthorized` so the user lands back at login.

Convention:

- Expose app state via a context hook: `const { appState, appDispatch } =
  useAppState();`.
- Pages call `appDispatch(...)` directly for cross-cutting messages. They do
  **not** invent a local `unauthorized` message and bubble it through their
  own reducer.
- `useAsync` does not know about auth. Failures carry a typed `ApiError`,
  and the container inspects them at the boundary. Pattern:

```ts
useEffect(() => {
  for (const r of [model.log, model.food, model.units]) {
    if (r.status === "failure" && isUnauthorized(r.error)) {
      appDispatch({ type: "auth/unauthorized" });
      return;
    }
  }
}, [model.log, model.food, model.units]);
```

In practice this should be extracted into a small pattern hook
(e.g. `useUnauthorizedDispatch([model.log, ...])`) so every page does not
repeat the loop.

This keeps the page reducer ignorant of global concerns and keeps the
app-level reducer the single owner of auth transitions.

## What Should Use Reducers

Use page-level reducers where several state fields change together or where
workflow correctness matters:

- loading/error/data transitions
- submit flows
- delete confirmation flows
- form state with validation and derived state
- date/page/search transitions that trigger loading
- optimistic or multi-step API interactions

Keep `useState` for simple isolated UI state:

- a single input draft
- menu open/closed
- autocomplete cursor
- temporary visual state
- local component-only toggles

The goal is not zero `useState`. The goal is that important behavior is pure,
explicit, and testable.

## Page Migration Plan

### 1. Auth And Theme

Move global auth/theme behavior into an app-level model before migrating any
page. Subsequent page migrations consume this layer for cross-cutting
messages (e.g., 401 → `auth/unauthorized`), and `darkMode` lives here from
the start so no page ever owns it.

Suggested messages:

```ts
type AppMsg =
  | { type: "app/started" }
  | { type: "auth/sessionLoaded"; identity: IdentityResponse | null; profile: ProfileResponse | null }
  | { type: "auth/sessionFailed" }
  | { type: "auth/loginSucceeded"; identity: IdentityResponse; profile: ProfileResponse }
  | { type: "auth/logoutSucceeded" }
  | { type: "auth/unauthorized" }
  | { type: "theme/loaded"; darkMode: boolean }
  | { type: "theme/toggled" };
```

Shape: a pure `appReducer(state, msg)` plus an `AppProvider` that wraps the
app tree, exposes `{ appState, appDispatch }` through a context, and runs a
small number of focused `useEffect`s for side effects:

- On mount: call `getSession()` and `checkBootstrapStatus()`, dispatch
  results into the reducer (using the same `useAsync` pattern as pages).
- Watch `appState.darkMode`: apply the class to `document.documentElement`
  and persist to `localStorage`.
- Watch `appState` for transitions that imply navigation (e.g.
  `auth/unauthorized`) and call `navigate(...)` from the provider.

No `AppEffect` enum, no app-level effect runner. The app layer mirrors the
page layer: pure reducer + a small impure provider component with named
`useEffect`s. This keeps the framework surface flat — the most cross-cutting
piece is not also the most framework-like.

Test focus:

- app startup session success/failure
- bootstrap status success/failure
- logout clears user state
- unauthorized clears user state and requests login navigation
- theme toggle updates model and emits apply/persist effect

### 2. Diary

Status: first reducer pass is in place in `src/pages/Diary.tsx`.

Next steps:

- Move `DiaryModel`, `DiaryMsg`, `diaryReducer`, and init helpers to
  `src/pages/diary/state.ts`.
- Drop `darkMode` from the Diary model entirely — it now lives in app state
  from §1. The theme toggle in Diary's UI dispatches through `appDispatch`,
  not the page reducer.
- Move API orchestration to `useAsync(Chain)` calls in the container, and
  migrate load/error fields to `RemoteData<T>` (see "Async Resources").
- Extract JSX to `src/pages/diary/DiaryView.tsx`.
- Keep `src/pages/Diary.tsx` as the container.
- Consider `UpdateResult` only after the simple split is stable.

Test focus:

- `prevDate` / `nextDate` pure helpers (date arithmetic, month/year rollover)
- `urlChanged` updates the mirrored `date` in the model
- loading success/failure transitions
- macro mode toggle
- item-name fallback behavior

### 3. MealDetail

Good candidate because it has multiple independent workflows:

- load meal detail
- load product names
- load units
- calculate nutrition
- delete confirmation
- log meal

Split into:

```txt
src/pages/meal-detail/state.ts
src/pages/meal-detail/effects.ts
src/pages/meal-detail/MealDetailView.tsx
```

Test focus:

- initial load transitions
- nutrition loading success/failure
- delete confirmation open/cancel/confirm
- log meal success/failure

### 4. MealForm

Good candidate because form edits and validation are workflow logic.

Reducer should own:

- edit/create mode model
- name, notes, quantity/unit
- component rows
- validation state
- submit lifecycle
- edit-mode load lifecycle

Test focus:

- adding/removing component rows
- updating component fields
- validation failures
- submit payload construction
- edit-mode hydration

### 5. FoodLogDetail

Reducer should own:

- log loading
- food/unit loading
- edit values
- save lifecycle
- delete lifecycle
- error states

Test focus:

- load success/failure
- field edits
- save success/failure
- delete success/failure
- item-name fallback behavior

### 6. AdminDashboard

Reducer should own:

- user list loading
- create-user form visibility and values
- create-user submit lifecycle
- reset-password state
- error states

Test focus:

- list load success/failure
- create form open/close
- create validation and success
- reset password flow

### 7. CustomFoodForm And Custom Food Pages

`CustomFoodForm` has enough structured state to benefit from a reducer, but keep
the create/edit pages as containers.

Reducer should own:

- base food fields
- nutrient rows
- serving rows
- validation
- payload construction
- submit lifecycle

Test focus:

- nutrient row edits
- serving row edits
- required-field validation
- payload construction for create/edit

### 8. FoodSearch

Do this after the heavier pages.

Potential reducer state:

- query
- results
- loading/error
- active autocomplete cursor
- category suggestions

Keep the search input component local if it remains easier to reason about.

Test focus:

- query changes
- search lifecycle
- empty result handling
- autocomplete cursor behavior

### 9. Small Detail/List Pages

Pages like `FoodDetail`, `Meals`, `CustomFoodCreate`, and `CustomFoodEdit` can be
migrated opportunistically.

Do not split them until there is a reason:

- repeated loading/error logic
- complicated submit behavior
- hard-to-test derived state

## Suggested Order

0. Land `src/lib/remoteData.ts` and `src/hooks/useAsync.ts` (plus
   `useAsyncChain`). The Diary split in step 2 should use them from the start.
1. Add app-level auth/theme state.
2. Finish the Diary split.
3. Migrate `MealDetail`.
4. Migrate `MealForm`.
5. Migrate `FoodLogDetail`.
6. Migrate `AdminDashboard`.
7. Migrate `CustomFoodForm`.
8. Revisit `FoodSearch`.
9. Clean up smaller pages as needed.

## Testing Strategy

For each migrated page, prefer pure reducer tests over component tests for
workflow logic.

Add reducer tests first:

- one test per message that changes behavior
- one test for important impossible/guarded transitions
- one test for payload/effect construction where applicable

Then scrutinize the existing component tests. If a component test mostly proves a
state transition that is now owned by the reducer, move that assertion into a
pure reducer test and delete the component test.

Examples of tests that should usually become reducer tests:

- loading starts and clears stale errors
- loading success stores data
- loading failure stores an error
- date/search/filter changes update the model
- submit/delete confirmation state changes
- form validation results
- derived payload/effect construction
- theme/auth messages update model state

Keep component tests only when they prove something the reducer cannot:

- route integration
- provider integration
- important accessibility wiring
- a simple smoke test that the page renders
- a user interaction whose value is specifically DOM behavior
- a regression involving layout, focus, or actual rendered text composition

When keeping a component test, keep it small. Avoid large tests that mock auth,
router, several APIs, user events, and then assert state-machine behavior
through the DOM. Those are slower, more brittle, and duplicate reducer coverage.

For migrated pages, the preferred test balance is:

- many small reducer tests
- a small number of smoke/integration component tests only when needed
- no indirect component test for behavior already covered by reducer tests

## Stop Conditions

Do not migrate a page just to satisfy architectural consistency. Stop when:

- workflow logic is in pure functions
- render code mostly receives `model` and dispatches messages
- API/theme/auth effects are isolated
- tests cover the reducer transitions
- remaining `useState` calls are simple and local
