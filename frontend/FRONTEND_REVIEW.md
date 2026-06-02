# Frontend Review

Remaining issues from a read-through of `frontend/src`. Items already addressed
in commits `9f94f3e`, `3bea777`, `ad2bc19`, and `d23b712` have been removed.
Original numbering is preserved for traceability with prior discussion.

## UX / data-flow gaps

### 15. Diary date navigation doesn't update the URL
`getInitialDate` reads `?date=`, but `goPrev/goNext` only update local state. Refresh loses position; deep-linking is one-way.

### 16. `FoodLogDetail` doesn't navigate or confirm after save
**File:** `FoodLogDetail.tsx:127-134`

It just calls `setLog(updated)`; user has no feedback that the save succeeded. Inconsistent with `FoodDetail` which navigates home.

### 17. Hard-coded macro goals
**File:** `Diary.tsx` (constants now live in `lib/nutrition`)

Calorie 2000, protein 150, carbs 250, fat 65 are baked in as `DEFAULT_CALORIE_GOAL` / `MACRO_COLORS`. The `profile` object has no nutrition targets, so this can't ever be personalized as-is.

### 18. `Meals.tsx` uses a `<Card>` div as a clickable row
**File:** `Meals.tsx:72-85`

Not keyboard-focusable, not announced as a link. Should be a `<Link to>` or `<button>`.

### 19. Lost route state on reload
`FoodSearch` reads `mealSlot` from `location.state`. Hard-reloading the search page drops the slot context silently. Better in a query param.

### 20. Meal components restricted to `type: "product"`
**File:** `MealForm.tsx:233`

Meals can't contain meals despite the API modeling `ItemRef` generically (and `ItemRef.type` now being the union `"product" | "meal"`).

## Architecture / code quality

### 23. No data layer / cache
Every navigation refetches units, nutrients (static), food details, etc. `listUnits`/`listNutrients` data essentially never changes — easy win with react-query or even a simple in-memory cache.

### 24. N+1 fetches for log item names
**Files:** `Diary.tsx:243-258`, `MealDetail.tsx:79-86`

For a day with N foods + M meals, that's N+M parallel GETs. Either include the name in the log/meal response or add a batch endpoint.

### 26. `IdentityResponse.role: string` instead of `"admin" | "user"`
**File:** `api/auth.ts:10`

String compares like `identity?.role === "admin"` are typo-prone with no compiler help.

### 27. No `ErrorBoundary` anywhere
A render error in any page blanks the entire app.

### 28. `apiRequest` always sets `Content-Type: application/json` even on GET
**File:** `api/client.ts:22-25`

Harmless but technically wrong for GETs without bodies.

### 29. `apiRequest` has no timeout / AbortSignal support
Slow backend = indefinite "Loading...". (Search endpoints accept a signal, but the generic `apiRequest` does not enforce a timeout.)

### 30. `notes` / `meal_slot` send `null` vs `undefined` inconsistently
`FoodDetail.tsx:103` uses `undefined`; `FoodLogDetail.tsx:130-131` uses `null`. Pick one — server may treat them differently (omit vs explicit clear).

## Accessibility

- Diary header arrows `←/→` use literal characters in spans (`Diary.tsx:365, 375`). Aria-labels are present on the buttons, but consider proper icons (Lucide's `ArrowLeft/Right`).
- `Meals.tsx` row Cards: see #18.
- The mobile ring carousel relies on scroll snap but has no keyboard nav between tiles.
- Reset-password input in `AdminDashboard` lacks a label.
- No password visibility toggle on Login / BootstrapAdminSetup / AdminDashboard.

## Smaller stuff

- `SubmitEvent<HTMLFormElement>` imported from `"react"` in `LoginPage`, `BootstrapAdminSetup`, `CustomFoodForm`, `MealForm`. React doesn't export `SubmitEvent` — the DOM has one but it's not generic. If `tsc -b` passes this is moot, otherwise it should be `React.FormEvent<HTMLFormElement>`. Worth a `pnpm build` to confirm.
- `RootRedirect.adminExists` defaults to `true` on error — fine as a fail-closed choice, but worth a comment about why.
- `AdminDashboard`: admin can disable / reset themselves with no guardrail (could lock themselves out). At minimum, hide those actions on the current user row.
- API base URL is hard-coded to relative `/api/...` — fine if always co-served, but no `VITE_API_BASE_URL` escape hatch.
