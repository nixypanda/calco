# Frontend Review

Issues found during a read-through of `frontend/src` (`App.tsx`, auth/api layer, all pages, key components, lib helpers). Ordered roughly by impact.

## Correctness bugs

### 1. `navigate(...)` called during render
**Files:** `LoginPage.tsx:18-21`, `BootstrapAdminSetup.tsx:18-21`

```tsx
if (isAuthenticated) {
  navigate(isAdmin ? "/admin" : "/", { replace: true });
  return null;
}
```

Side-effects in render are an anti-pattern (StrictMode warns, can cause double-fires). Use `<Navigate to=... replace />` JSX instead.

### 2. Date / timezone mismatch between log creation and diary filtering
`createLog` uses `new Date().toISOString()` (UTC), but `Diary.formatDate` builds `YYYY-MM-DD` in local time and queries `listLogs(dateStr, dateStr)`. In negative-UTC offsets, a log created at 11pm local can land on the *next* day in UTC and disappear from "today" — and reverse near midnight in positive offsets. Either send local-zoned timestamps or include a TZ in the query.

### 3. Race condition in `Diary.fetchData`
**File:** `Diary.tsx:222-267`

No `cancelled` guard like the other pages have. Rapid prev/next clicks can let an older response overwrite a newer one (e.g., `foodNames` briefly showing the prior day's items).

### 4. `MealForm` loses product names on edit
**File:** `MealForm.tsx:99-109`

When loading an existing meal, each row's `productName` and `searchQuery` are set to `""`. Users see blank search inputs with no indication which products are linked; if they save without re-touching, they're submitting against stale `productId`s with a confusing UI.

### 5. `NumberStepper` formatting drops tiny values
**File:** `FoodLogEntry.tsx:40`

```ts
next.toFixed(2).replace(/\.?0+$/, "")
```

For `next = 0.005` → `"0.00"` → `""`, so the input becomes empty after stepping. Same for any value < 0.005.

### 6. `Diary` ring-tile pagination is hard-coded to 2 tiles
**File:** `Diary.tsx:454`

`[0, 1].map(...)` — if you ever add another card, the dots silently break.

### 7. `MealForm.searchTimers` keyed by array index
**File:** `MealForm.tsx:83, 156-159`

After `removeComponent(idx)`, indexes shift but timers stay keyed to old indexes; a fired timer can update a row that no longer exists. Use a stable `rowId` per row.

### 8. Search requests have no abort / cancellation
**Files:** `FoodSearch.tsx:40-50`, `SearchQueryInput.tsx:84-102`, `MealForm.doSearch`

Same race as #3: "abc" results can arrive after "abcd" overwrote them.

### 9. `SearchQueryInput` fires category-suggestion API on every keystroke
`useEffect([categoryQuery, prefix])` with no debounce — spams the backend while typing inside a `category:` token.

### 10. No global 401 handling in `apiRequest`
**File:** `api/client.ts`

When the session expires server-side, every page just shows "Unauthorized" without logging the user out or routing to `/login`. A 401 interceptor should clear auth state and redirect.

### 11. `LoginPage` doesn't trim before login call
**File:** `LoginPage.tsx:32`

Validation checks `username.trim()`, but the actual call passes the untrimmed value. A user typing `" alice "` passes validation but logs in with leading/trailing spaces, which the backend may or may not accept.

### 12. `MealDetail` requires "Calculate" before "Log Meal"
**File:** `MealDetail.tsx:250-277`

Log button is gated on the nutrients panel rendering. Changing amount after calculating leaves stale nutrients shown. Either auto-recalc on amount change or decouple the log action.

### 13. `MealDetail` log unit is hard-coded to `"g"`
**File:** `MealDetail.tsx:48, 242-249`

The select is disabled with only "g" available, despite the API accepting any unit.

### 14. `AdminDashboard.fetchUsers` not in `useEffect` deps
**File:** `AdminDashboard.tsx:52-54`

Standard exhaustive-deps lint violation; `fetchUsers` isn't wrapped in `useCallback`.

## UX / data-flow gaps

### 15. Diary date navigation doesn't update the URL
`getInitialDate` reads `?date=`, but `goPrev/goNext` only update local state. Refresh loses position; deep-linking is one-way.

### 16. `FoodLogDetail` doesn't navigate or confirm after save
**File:** `FoodLogDetail.tsx:127-134`

It just calls `setLog(updated)`; user has no feedback that the save succeeded. Inconsistent with `FoodDetail` which navigates home.

### 17. Hard-coded macro goals
**File:** `Diary.tsx:45, 391/398/406`

Calorie 2000, protein 150, carbs 250, fat 65 are baked in. The `profile` object has no nutrition targets, so this can't ever be personalized as-is.

### 18. `Meals.tsx` uses a `<Card>` div as a clickable row
**File:** `Meals.tsx:72-85`

Not keyboard-focusable, not announced as a link. Should be a `<Link to>` or `<button>`.

### 19. Lost route state on reload
`FoodSearch` reads `mealSlot` from `location.state`. Hard-reloading the search page drops the slot context silently. Better in a query param.

### 20. Meal components restricted to `type: "product"`
**File:** `MealForm.tsx:212`

Meals can't contain meals despite the API modeling `ItemRef` generically.

## Architecture / code quality

### 21. Duplication: `CustomFoodCreate.tsx` and `CustomFoodEdit.tsx`
~95% identical (Basic Info / Portion / Nutrients / Servings sections). Extract a shared `CustomFoodForm`.

### 22. Duplicate type defs across api modules
`QuantityDto` is declared in both `api/meals.ts:3` and `api/logs.ts:3`. `ItemRef`/`{type, id}` is inlined in many places. Move to a shared `api/types.ts`.

### 23. No data layer / cache
Every navigation refetches units, nutrients (static), food details, etc. `listUnits`/`listNutrients` data essentially never changes — easy win with react-query or even a simple in-memory cache.

### 24. N+1 fetches for log item names
**Files:** `Diary.tsx:243-258`, `MealDetail.tsx:79-86`

For a day with N foods + M meals, that's N+M parallel GETs. Either include the name in the log/meal response or add a batch endpoint.

### 25. Bootstrap status fetched twice on app boot
Both `RootRedirect` and `BootstrapGate` independently call `checkBootstrapStatus`. Should be hoisted to `AuthProvider` (or memoized).

### 26. `IdentityResponse.role: string` instead of `"admin" | "user"`
**File:** `api/auth.ts:10`

String compares like `identity?.role === "admin"` are typo-prone with no compiler help.

### 27. No `ErrorBoundary` anywhere
A render error in any page blanks the entire app.

### 28. `apiRequest` always sets `Content-Type: application/json` even on GET
**File:** `api/client.ts:18-21`

Harmless but technically wrong for GETs without bodies.

### 29. `apiRequest` has no timeout / AbortSignal support
Slow backend = indefinite "Loading...".

### 30. `notes` / `meal_slot` send `null` vs `undefined` inconsistently
`FoodDetail.tsx:103` uses `undefined`; `FoodLogDetail.tsx:130-131` uses `null`. Pick one — server may treat them differently (omit vs explicit clear).

## Accessibility

- Diary header arrows `←/→` use literal characters in spans (`Diary.tsx:365, 375`). Aria-labels are present on the buttons, but consider proper icons (Lucide's `ArrowLeft/Right`).
- `Meals.tsx` row Cards: see #18.
- The mobile ring carousel relies on scroll snap but has no keyboard nav between tiles.
- Reset-password input in `AdminDashboard` lacks a label.
- No password visibility toggle on Login / BootstrapAdminSetup / AdminDashboard.

## Smaller stuff

- `SubmitEvent<HTMLFormElement>` imported from `"react"` in `LoginPage`, `BootstrapAdminSetup`, `CustomFoodCreate`, `CustomFoodEdit`, `MealForm`. React doesn't export `SubmitEvent` — the DOM has one but it's not generic. If `tsc -b` passes this is moot, otherwise it should be `React.FormEvent<HTMLFormElement>`. Worth a `pnpm build` to confirm.
- `RootRedirect.adminExists` defaults to `true` on error — fine as a fail-closed choice, but worth a comment about why.
- `AdminDashboard`: admin can disable / reset themselves with no guardrail (could lock themselves out). At minimum, hide those actions on the current user row.
- API base URL is hard-coded to relative `/api/...` — fine if always co-served, but no `VITE_API_BASE_URL` escape hatch.
