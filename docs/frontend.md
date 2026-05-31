# Frontend

## Overview

The frontend is a React/Vite/TypeScript app with Tailwind CSS and local shadcn-style UI primitives.

```text
frontend/src/
  api/
  components/
  components/ui/
  hooks/
  pages/
  App.tsx
  index.css
```

The target is a responsive web UI that works well on mobile browsers and can be pinned to the home screen by the browser. Service-worker/offline behavior is out of current scope.

## Routes

Current routes in `frontend/src/App.tsx`:

```text
/setup
/login
/admin
/home
/logs/:id
/search
/foods/:id
/foods/custom/new
/foods/custom/:id/edit
/meals
/meals/new
/meals/:id
/meals/:id/edit
/
*
```

Route guards:

- `ProtectedRoute`: normal authenticated users only.
- `AdminRoute`: admin users only.
- Admin identities cannot access food-tracking routes.

## Pages

### Auth

- `BootstrapAdminSetup`
- `LoginPage`
- `AdminDashboard`

The first-run flow creates a bootstrap admin. Admins create and manage normal user accounts.

### Diary

`Diary` is the main authenticated user screen.

It provides:

- Selected-day date navigation.
- Calorie and macro summary.
- Meal-slot grouped logs.
- Add-food actions per meal slot.
- Profile menu with meals, theme toggle, and logout.

Users can inspect previous days with the diary date selector. A separate history/trends screen is out of scope.

### Foods

- `FoodSearch`
- `FoodDetail`
- `CustomFoodCreate`
- `CustomFoodEdit`

Custom foods use the same catalog model as imported/global foods, scoped by user ownership.

### Logs

`FoodLogDetail` supports viewing, editing quantity/unit/meal slot/notes, and deleting a log.

Editing logged timestamp or swapping the selected item is intentionally not required for current scope.

### Meals

- `Meals`
- `MealDetail`
- `MealForm`

Meal forms edit components inside the aggregate. There are no independent component screens.

## API Client

API modules live in `frontend/src/api/`:

- `auth.ts`
- `admin.ts`
- `foods.ts`
- `logs.ts`
- `meals.ts`
- `client.ts`

`apiRequest` sends credentials with requests so the server-managed session cookie is included.

## Design Direction

The UI should stay functional and food-diary oriented:

- Mobile-first responsive layouts. Small screens are the primary target, so UI/UX work should be designed and reviewed on mobile widths first.
- Fast repeated logging.
- Dense enough for daily use without becoming a spreadsheet.
- No marketing landing page.
- No analytics dashboard unless product scope changes.

Search, diary, and logging surfaces should prioritize compact, scannable controls and rows. Avoid oversized cards, large text that truncates early, or layouts that only work comfortably on desktop widths.

The app uses local UI primitives in `components/ui/` for buttons, inputs, selects, cards, dialogs, tables, badges, dropdown menus, labels, and skeleton states.

## Tests

Frontend unit tests live in:

```text
frontend/src/__tests__
```

Run:

```bash
cd frontend && pnpm test
```

Build:

```bash
cd frontend && pnpm run build
```

No e2e suite is configured at the moment.
