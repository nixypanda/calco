# Frontend Design Plan

## Summary

Build the frontend as a Progressive Web App optimized for quick daily food logging on mobile, while scaling up to denser dashboard layouts on larger screens.

The product interaction model should closely follow the familiar MyFitnessPal pattern:

- Today-first home screen.
- Large calorie summary.
- Macro summary nearby.
- Meal-slot grouped diary.
- Fast add-food actions from each meal slot.
- Detailed nutrition drill-downs when needed.

Do not build a marketing landing page. The first authenticated screen should be the food diary/home experience.

## PWA Requirements

Required:

- Responsive mobile-first UI.
- Installable web app manifest.
- iOS Safari Add to Home Screen support.
- Touch-friendly controls.
- Fast repeated logging flow.

Backend data should remain authoritative. Do not design offline logging or offline data access for MVP. If a service worker is needed for installability or static asset caching, it should not queue writes or imply offline functionality; show a simple network-required state when the API is unavailable.

## Navigation Model

Primary navigation:

```text
Home / Diary
Search
Foods
Meals, later
Reports, later
Settings
```

Mobile:

- Bottom tab navigation.
- Floating or prominent add action in meal sections.

Desktop/tablet:

- Left sidebar or top navigation.
- Sidebar should contain navigation only, not duplicate calorie, macro, or goal summary content.
- Wider dashboard content.
- Denser diary rows with nutrient columns.

## Visual Identity

Use a quiet, data-dense nutrition diary aesthetic rather than a lifestyle/marketing wellness aesthetic.

The starting visual baseline is the cleaner mockup direction:

- MyFitnessPal-like diary structure.
- Lighter density than a spreadsheet/dashboard.
- Circular rings only.
- No repeated macro or goal summaries in multiple regions.
- iPhone starts calorie-first with swipeable macro summary.
- iPad shows the top calorie/macro summary once in the main content area.
- iPad sidebar is navigation-only.
- iPad side panel is for detail content only.

Direction:

- Familiar food diary layout inspired by MyFitnessPal, without copying brand colors, assets, icons, or exact screens.
- Neutral app background with white or near-white surfaces.
- Compact typography, strong numeric hierarchy, and clear table-like alignment on larger screens.
- Circular rings only for calorie and macro summary progress.
- Use relaxed spacing on mobile and moderate density on tablet/desktop.
- Avoid repeating the same calorie/macro/goal information in the top summary, sidebar, and detail panel.
- Functional color coding for nutrients:
  - Calories: green.
  - Protein: blue.
  - Carbs: amber.
  - Fat: rose/red.
  - Neutral text and borders: gray.
- Avoid a one-color palette. The app should read as a utilitarian food diary, not a branded purple/blue gradient dashboard.

Typography:

- Prefer system font stack or Inter.
- Large numerals for calorie totals.
- Compact labels and row text for diary entries.
- No viewport-scaled font sizing.

Inspiration references:

- MyFitnessPal for diary-first information architecture and calorie/macro overview.
- Cronometer for detailed nutrient depth and micronutrient credibility.
- MacroFactor for dense macro-focused dashboards and trend clarity.
- Lose It for simple, friendly logging flows.
- MyNetDiary for detailed nutrition breakdowns and broad nutrient coverage.
- Lifesum/YAZIO for lighter visual treatments, but avoid making the app too lifestyle/editorial.

## Home / Diary View

The home screen is the primary daily logging screen.

### Top Summary Area

Mobile:

- Show a calorie count tile first.
- The calorie tile can slide horizontally to reveal the macro counts tile.
- Dots or segmented indicator should make the swipeable summary discoverable.
- Do not show macro totals below the calorie tile, because the macro tile is available by swiping.

Desktop/tablet:

- Show calorie tile and macro counts tile side by side.
- Do not repeat the same calorie/macro summary in the sidebar or detail panel.

Calorie tile should show:

```text
Calories consumed
Date selector
```

Before goals exist, calorie and macro tiles use circular rings that are visually filled. Once goals exist, those same rings represent progress toward the active goal.

Macro tile should show:

```text
Protein
Carbs
Fat
Each as grams
```

### Meal-Slot Diary

Below the summary area, show food logs for the selected day grouped by meal slot.

Default meal slots:

```text
Breakfast
Lunch
Dinner
Snacks 1
Snacks 2
Snacks 3, etc. as needed
```

Meal slots are not customizable. Use the standard slots everywhere. Snack slots are generated as a simple counter when additional snack groups are needed.

Each meal slot should show:

- Slot name.
- Slot calorie total.
- Slot macro totals in grams and percentages.
- Food log rows.
- Add food action.

Mobile food log row:

```text
Food name
Quantity
Calories
Tap for details/edit
```

Desktop/tablet food log row:

```text
Food name
Quantity
Calories
Protein
Carbs
Fat
Edit/delete actions
```

Meal-slot stats:

```text
Calories
Protein grams and percent
Carbs grams and percent
Fat grams and percent
```

Percentages should be clearly defined during implementation:

- In the diary meal-slot stats, percentage means the meal slot's share of the selected day's consumed calories/macros.
- In the top summary tiles, circular rings are always visually filled before goals exist.
- Once goals exist, top summary tile circular rings represent progress toward the active goal.

## Full Nutrition Detail View

Add a separate detail view for full macro and micronutrient breakdown.

Entry points:

- From home summary tile.
- From daily summary.
- From a food log.
- From reports.

Daily detail should show:

- Calories.
- Core macros.
- Fiber/sugar/fat breakdown.
- Sodium/cholesterol/potassium.
- Any tracked micronutrients.

Food log detail should show:

- Logged item.
- Quantity.
- Meal slot.
- Logged time.
- Snapshotted nutrients.
- Edit/delete actions.

Food detail should show:

- Product metadata.
- Per-100g nutrients.
- Serving options.
- Add/log action.

## Required MVP Views

### Auth / First Run

Views:

- Bootstrap admin setup.
- Login.
- Current session/loading state.
- Logout action.
- Admin user management.
- User profile/settings.
- Change password.

Required flows:

- If no admin exists, show bootstrap admin setup.
- Admin can create users and reset passwords.
- Admin cannot access food diary features.
- Normal users land on Home / Diary after login.

### Home / Diary

Views:

- Today diary.
- Date selector for previous/next day.
- Grouped meal slots.
- Daily summary tiles.
- Food log detail/edit side panel on large screens.
- Food log detail/edit full-screen view or drawer on small screens.

APIs:

```text
GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD
GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...
POST /logs
PUT /logs/{id}
DELETE /logs/{id}
```

### Food Search And Logging

Views:

- Food search.
- Barcode search result, later scanner input.
- Food detail.
- Quantity/serving picker.
- Confirm log screen or bottom sheet.
- Custom foods appear in the same search results as global/catalog foods.

APIs:

```text
GET /foods/search?q=...
GET /foods/barcode/{barcode}
GET /foods/{id}
GET /units
POST /logs
```

### Custom Foods

Views:

- Custom food list/filter.
- Create custom food.
- Edit custom food.
- Custom food detail.

APIs:

```text
GET /foods/search?q=...
GET /foods/{id}
GET /nutrients
GET /units
POST /foods/custom
PUT /foods/custom/{id}
DELETE /foods/custom/{id}
```

### History

Views:

- Date range summary.
- Daily history list.
- Nutrition detail by date.

This is for reviewing logs and totals. Charting and analytics reports are strictly later.

APIs:

```text
GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...
GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD
```

## Next Feature Views

### Meals / Recipes

Views:

- Meal list.
- Create meal.
- Edit meal.
- Meal detail.
- Meal nutrition preview.
- Log meal flow.

Behavior:

- Meal create/edit should use aggregate-shaped forms.
- Components are edited inside the meal form, not through separate screens as independent resources.
- Logging a meal should reuse the normal log flow with `item.type = meal`.

APIs:

```text
POST /meals
GET /meals
GET /meals/{id}
PUT /meals/{id}
DELETE /meals/{id}
GET /meals/{id}/nutrients?quantity=&unit=
POST /logs
```

### Imports / Admin

Views:

- Import job list.
- Create import job.
- Upload/stage food rows.
- Upload/stage nutrient rows.
- Import status.
- Import errors table.
- Commit import confirmation.

Admin-only.

APIs:

```text
POST /imports
POST /imports/{id}/foods
POST /imports/{id}/nutrients
POST /imports/{id}/commit
GET /imports/{id}
GET /imports/{id}/errors
```

### Nutrition Goals

Views:

- Goal list.
- Create/edit goal.
- Active goal display.
- Goal progress on diary/home.
- Goal progress detail.

APIs:

```text
POST /goals
GET /goals
GET /goals/active?date=YYYY-MM-DD
GET /goals/{id}
PUT /goals/{id}
DELETE /goals/{id}
GET /goals/progress?date=YYYY-MM-DD
```

## Later Feature Views

### Barcode Scanning

Views:

- Camera scanner.
- Manual barcode entry fallback.
- Barcode result screen.

Backend uses:

```text
GET /foods/barcode/{barcode}
```

### Direct Catalog Corrections

Admin-only views:

- Global food detail edit.
- Imported food correction form.

APIs:

```text
PUT /admin/foods/{id}
```

### Export Jobs

Views:

- Export request form.
- Export job status.
- Download export.

APIs:

```text
POST /exports
GET /exports/{id}
GET /exports/{id}/download
```

### Reports And Analytics

Views:

- Nutrient trend charts.
- Macro trend charts.
- Goal progress over time.
- Calendar/weekly/monthly summaries.

APIs:

```text
GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...
GET /reports/nutrients/timeseries?from=YYYY-MM-DD&to=YYYY-MM-DD&interval=day&codes=...
GET /reports/goals/progress?from=YYYY-MM-DD&to=YYYY-MM-DD
```

## Missing Or Needs Product Decisions

Resolved decisions:

- Meal slots are fixed: breakfast, lunch, dinner, and numbered snack slots.
- Diary meal-slot percentages mean share of the selected day's consumed calories/macros.
- Home summary uses circular rings only. Rings are visually filled before goals exist and become goal-progress indicators after goals exist.
- Compact diary nutrient columns are limited to calories, protein, carbs, and fat.
- Custom foods appear in the same search results as global/catalog foods.
- Food log edit/detail is side by side on large screens and a full-screen view or drawer on small screens.
- Reports are strictly later.
- Offline behavior is out of scope for MVP and should not be designed unless revisited later.

Open decisions:

- Visual identity: color palette, typography, density, and tone.

## Design Notes

- Keep the UI work-focused and dense, not a marketing-style dashboard.
- Use cards only for repeated items, summary tiles, modals, and framed tools.
- Avoid nested cards.
- Use familiar icon buttons for common actions such as add, edit, delete, search, calendar, and scan.
- Keep touch targets large enough for mobile diary use.
- Do not hardcode only calories/macros in API-driven UI models; full nutrition detail should work with any nutrient code returned by the backend.
