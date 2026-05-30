# Migration Prompt: shadcn/ui Page Migration

## Context

The project (`CalCo`) is a calorie tracking app with a React + Vite frontend. It currently uses plain CSS (`src/index.css`, ~1400 lines) for all styling. **Tailwind CSS v4 + shadcn/ui has been installed and configured.** The CSS variables for theming (`--primary`, `--background`, etc.) and dark mode (`.dark` class) are set up. Twelve shadcn component files exist in `src/components/ui/`.

Your job is to **migrate pages one by one** from plain CSS + HTML elements to Tailwind utilities + shadcn components.

## What's already done (do not redo)

- Tailwind CSS v4 + `@tailwindcss/vite` installed and configured in `vite.config.ts`
- `@import "tailwindcss"` added to `src/index.css`
- `@theme` block with custom colors (`brand`, `brand-pressed`, `macro-calories`, `macro-protein`, `macro-carbs`, `macro-fat`)
- shadcn CSS variables on `:root` (light) and `.dark` (dark mode) — primary = `#007aff` (HSL 211 100% 50%)
- `components.json`, `src/lib/utils.ts` with `cn()` helper
- 12 components in `src/components/ui/`: Button, Input, Label, Select, Card, Badge, Table, Avatar, DropdownMenu, Dialog, Popover, Skeleton, Separator
- Radix UI primitives and other deps installed
- Build passes (`pnpm run build`)

## Custom colors available as Tailwind utilities

```
bg-brand / text-brand           → #007aff
bg-brand-pressed / text-brand-pressed → #0066d6
bg-macro-calories / text-macro-calories → #007aff
bg-macro-protein / text-macro-protein → #ff9f0a
bg-macro-carbs / text-macro-carbs → #34c759
bg-macro-fat / text-macro-fat   → #ffcc00
bg-background / text-foreground → CSS variable (light/dark)
bg-primary / text-primary       → #007aff (shadcn primary)
bg-muted / text-muted-foreground → CSS variable (light/dark)
```

## Migration order (simplest first)

### 1. LoginPage.tsx + BootstrapAdminSetup.tsx
- Replace `.auth-card` → `<Card>`
- Replace `.auth-card h1` → `<CardTitle>`
- Replace `.auth-card h2` → `<CardDescription>`
- Replace `<button>` → `<Button>`
- Replace `<input>` → `<Input>`
- Replace `<label>` → `<Label>`
- Replace form CSS classes with Tailwind `flex flex-col gap-2`
- Remove these CSS classes from `index.css` (only if all usages are migrated):
  - `.auth-card`, `.auth-card h1`, `.auth-card h2`, `.auth-card p`, `.auth-card form`, `.auth-card label`, `.auth-card input`, `.auth-card button`
  - `.auth-page`

### 2. Diary.tsx (most complex — main dashboard)
- Keep custom SVG components (`NutrientRing`, `MacroDonut`, `MacroStat`) and the `MACRO_COLORS` constants — **do not modify them**
- Keep `.diary-summary-tile` and `.meal-slot` container CSS for now (these are tightly coupled to the existing layout)
- Replace `.meal-add-btn` → `<Button variant="ghost">` + Tailwind
- Replace `<button>` in `.date-arrow`, `.profile-button`, etc. → `<Button>`
- Replace `.profile-popover` → shadcn `<DropdownMenu>`
- Replace `.profile-initials` → shadcn `<Avatar>`
- Replace `.profile-name` → `text-muted-foreground`
- Replace `.log-row-name` → `font-medium`
- Remove CSS classes for migrated elements

### 3. FoodSearch.tsx + FoodDetail.tsx + FoodLogDetail.tsx
- Replace `.search-bar input` → `<Input>`
- Replace `.search-result` → `<Card>`
- Replace `.category-chip`, `.source-chip` → `<Badge>`
- Replace `.btn-primary`, `.btn-secondary`, `.btn-danger` → `<Button variant="..."`>
- Replace `.nutrient-table` → shadcn `<Table>`
- Replace `.amount-input`, `.unit-select` → `<Input>` + `<Select>`
- Replace `.serving-item` → `<Card>`
- Replace `.meal-slot-select` → `<Select>`

### 4. Meals.tsx + MealForm.tsx + MealDetail.tsx
- Replace form inputs → `<Input>`, `<Select>`
- Replace buttons → `<Button>`
- Replace `.meal-component-row` search dropdown → `<Popover>`
- Replace inline confirm delete section → `<Dialog>`

### 5. History.tsx + CustomFoodCreate.tsx + CustomFoodEdit.tsx
- Replace `.history-table` → `<Table>`
- Replace date inputs → `<Input type="date">`
- Replace nutrient/serving rows → `<Input>`, `<Select>`, `<Button>`

### 6. AdminDashboard.tsx
- Replace table → `<Table>`
- Replace buttons → `<Button>`
- Replace inputs → `<Input>`

### 7. Cleanup
- Remove unused CSS from `index.css` after all pages are migrated
- Add dark mode toggle (a button that adds/removes `dark` class on `<html>`)

## General rules

1. **One page at a time.** Verify the build passes after each page (`pnpm exec tsc --noEmit && pnpm run build`).
2. **Don't modify custom SVG components** (`NutrientRing`, `MacroDonut`, `MacroStat`) or the `MACRO_COLORS` constants.
3. **Don't remove CSS from `index.css` until all usages of that class are migrated.** Keep the old CSS — it won't conflict with Tailwind utilities.
4. **Keep `.page-loading`, `.empty-state`**, and the page wrapper classes (`.diary-page`, `.catalog-page`, etc.) until all pages are done — they're used by multiple pages.
5. **Don't touch `AuthContext.tsx`, `ProtectedRoute.tsx`, `AdminRoute.tsx`** — they don't need styling changes.
6. **Import path pattern:** `import { Button } from "@/components/ui/button"`
7. **Use `cn()` for conditional classes:** `className={cn("base-classes", condition && "conditional", className)}`
8. **For responsive layout**, use Tailwind breakpoints: `sm:`, `md:`, etc.
9. **For dark mode**, add `dark:` variants: `className="bg-background dark:bg-gray-900"`
10. **Run `pnpm exec tsc --noEmit` to check for TypeScript errors** after each page migration.

## Example migration (LoginPage)

Before:
```tsx
<div className="auth-card">
  <h1>CalCo</h1>
  <h2>Track your nutrition</h2>
  <form onSubmit={handleLogin}>
    <label>
      Username
      <input type="text" value={username} onChange={...} />
    </label>
    <button type="submit">Log In</button>
  </form>
</div>
```

After:
```tsx
<Card className="w-full max-w-sm mx-auto p-6">
  <CardTitle className="text-2xl font-extrabold">CalCo</CardTitle>
  <CardDescription className="text-base">Track your nutrition</CardDescription>
  <form onSubmit={handleLogin} className="flex flex-col gap-4 mt-4">
    <div className="flex flex-col gap-2">
      <Label htmlFor="username">Username</Label>
      <Input id="username" type="text" value={username} onChange={...} />
    </div>
    <Button type="submit">Log In</Button>
  </form>
</Card>
```
