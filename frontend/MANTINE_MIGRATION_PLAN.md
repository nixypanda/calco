# Mantine Migration Plan

## Goal

Migrate this frontend from **shadcn/ui + Tailwind + Radix** to **Mantine v7** with its **default native look** (no theming to preserve the current visual identity). Drop Tailwind entirely. The user explicitly accepts losing the current painterly/gradient aesthetic in exchange for a smaller, more readable codebase that a junior React developer can navigate.

## Why

The current `components/ui/` folder is shadcn-generated source (10 files, 836 lines) full of `cva`, `cn`, `forwardRef`, and dense Tailwind selectors like `[&:has([role=checkbox])]:pr-0`. The user finds this unmaintainable and wants call sites that read like plain HTML/React. Mantine's API (`<Button variant="filled">`, `<Modal opened={...}>`) is the chosen target because it's the most beginner-readable mainstream option.

Trade-off accepted: bundle grows by ~35 KB gzip (from ~50 KB UI-portion today to ~85 KB), and the visual design will become stock Mantine.

## Current state (as of writing)

- Vite + React 19 + React Router 7
- UI primitives live in `src/components/ui/` (shadcn-generated): `badge`, `button`, `card`, `dialog`, `dropdown-menu`, `input`, `label`, `select`, `skeleton`, `table`
- Domain components in `src/components/`: `FoodLogEntry` (332 lines), `SearchQueryInput` (191), `FoodSearchResultRow` (103), `MacroBreakdown`, `MacroRing`, `NutrientsTable`, `PageHeader`, `FieldRow`, `EmptyState`, `ErrorBanner`, `ProtectedRoute`, `AdminRoute`
- Pages in `src/pages/`: `Diary`, `FoodSearch`, `FoodDetail`, `FoodLogDetail`, `CustomFoodCreate`, `CustomFoodEdit`, `Meals`, `MealDetail`, `MealForm`, `LoginPage`, `AdminDashboard`, `BootstrapAdminSetup`
- ~35 files contain `className=` (Tailwind)
- `src/index.css` defines a custom theme via `@theme inline` with HSL tokens and painterly gradient/blob variables — all of this gets thrown away
- `src/lib/utils.ts` contains the shadcn `cn()` helper — deleted at the end
- Tests use Testing Library and mostly query by role/label, so should survive

### Dependencies to remove
- `@radix-ui/react-dialog`, `@radix-ui/react-dropdown-menu`, `@radix-ui/react-label`, `@radix-ui/react-select`, `@radix-ui/react-slot`
- `clsx`, `tailwind-merge`
- `tailwindcss`, `@tailwindcss/vite`

### Dependencies to add
- `@mantine/core`, `@mantine/hooks`
- `postcss`, `postcss-preset-mantine`, `postcss-simple-vars` (devDeps)
- Possibly `@mantine/dates` and `@mantine/notifications` — **check first** whether any page currently uses a date picker or toast/notification pattern before installing

### Dependencies kept
- `react`, `react-dom`, `react-router-dom`
- `lucide-react` (icons — Mantine doesn't ship icons; optionally swap to `@tabler/icons-react` later for tighter integration, but not required)

## Primitive mapping

| shadcn (current) | Mantine target | Notes |
|---|---|---|
| `Button` | `Button` | `variant`: `default` → `filled`, `outline` → `outline`, `ghost` → `subtle`, `destructive` → `color="red"` |
| `Badge` | `Badge` | Direct |
| `Card` | `Card` or `Paper` | `Card` if it has header/sections, else `Paper` |
| `Dialog` | `Modal` | Note: portals to `document.body` |
| `DropdownMenu` | `Menu` | `Menu.Target` / `Menu.Dropdown` / `Menu.Item` |
| `Input` + `Label` | `TextInput` | Combined: `<TextInput label="..." />` |
| `Select` | `Select` or `NativeSelect` | Use `NativeSelect` for the simple short-list cases (meal slot, unit) — fewer lines, no portal |
| `Skeleton` | `Skeleton` | Direct |
| `Table` | `Table` | API differs — see Mantine docs |

## Execution plan

Work in small, reviewable commits. After each phase, run `npm run build` and `npm test` and confirm the app boots via `npm run dev`.

### Phase 0 — Setup (no UI changes)
1. Audit usage: grep for date pickers, toasts, or anything implying `@mantine/dates`/`@mantine/notifications` is needed. Install only what's used.
2. `npm i @mantine/core @mantine/hooks`
3. `npm i -D postcss postcss-preset-mantine postcss-simple-vars`
4. Create `postcss.config.cjs` per Mantine docs.
5. In `src/main.tsx`: add `import "@mantine/core/styles.css"` and wrap `<App/>` in `<MantineProvider>`.
6. Commit: "chore: install Mantine alongside Tailwind".
7. Verify app still builds and renders identically.

### Phase 1 — Replace primitives (one at a time)

Order, easiest to hardest, one commit per primitive:

1. **Skeleton** — trivial drop-in.
2. **Badge** — trivial.
3. **Button** — many call sites but mechanical; map variants per table above.
4. **Card** — check usage; may be a wrapper-only `<Card>` or have child slots.
5. **Input + Label** — collapse `<Label/><Input/>` pairs into `<TextInput label="...">`.
6. **Table** — used in `Diary` and food/nutrients views. Test row rendering carefully.
7. **Select** — 5 call sites: `FoodLogEntry`, `MealDetail`, `MealForm`, `CustomFoodCreate`, `CustomFoodEdit`. All are short lists; prefer `NativeSelect`.
8. **Dialog → Modal** — used in `FoodLogEntry` (and maybe elsewhere; grep). Note portal differences for tests.
9. **DropdownMenu → Menu** — single use in `Diary.tsx` for kebab/logout menu.

After each primitive's last import is gone, **delete the corresponding file from `src/components/ui/`**.

### Phase 2 — Convert layout from Tailwind to Mantine

This is the bulk of the work. For each file with `className="..."`:

- `flex flex-col` / vertical stacks → `<Stack gap="...">`
- `flex` / horizontal → `<Group gap="..." align="..." justify="...">`
- `grid grid-cols-N` → `<SimpleGrid cols={N}>`
- `gap-4`, `p-6`, `mt-2` → component props (`gap="md"`, `p="lg"`, `mt="xs"`) or `style={{}}`
- `text-sm`, `font-semibold`, `text-muted-foreground` → `<Text size="sm" fw={600} c="dimmed">`
- `text-2xl font-bold` headings → `<Title order={N}>`
- Container/max-width wrappers → `<Container size="...">`
- One-off styling that doesn't map cleanly → inline `style={{}}` is acceptable (we are intentionally going native; no need to preserve exact spacing)

Recommended file order (simple → complex, build skill before hitting the hard files):
1. `LoginPage`, `BootstrapAdminSetup` — small forms
2. `EmptyState`, `ErrorBanner`, `FieldRow`, `PageHeader` — tiny components
3. `ProtectedRoute`, `AdminRoute` — barely any styling
4. `MacroBreakdown`, `NutrientsTable`, `MacroRing` — display components (MacroRing has SVG; convert sizing to inline style or use Mantine `RingProgress` if it fits)
5. `FoodSearchResultRow`, `SearchQueryInput`
6. `AdminDashboard`, `Meals`, `MealDetail`, `MealForm`, `CustomFoodCreate`, `CustomFoodEdit`, `FoodSearch`, `FoodDetail`, `FoodLogDetail`
7. **`Diary.tsx`** and **`FoodLogEntry.tsx`** last — biggest, most complex

### Phase 3 — Rip out Tailwind

Only after `grep -r "className=" src/` returns nothing meaningful (Mantine accepts `className` for CSS modules; that's fine, just confirm no Tailwind classes remain).

1. Delete the `@import "tailwindcss"` line and the `@theme` block from `src/index.css`. Either delete the file entirely or keep a minimal global reset.
2. `npm uninstall tailwindcss @tailwindcss/vite tailwind-merge clsx`
3. Remove the Tailwind plugin from `vite.config.ts`.
4. Delete `src/lib/utils.ts` (the `cn` helper).

### Phase 4 — Drop Radix

Once `src/components/ui/` has no remaining files:

1. `npm uninstall @radix-ui/react-dialog @radix-ui/react-dropdown-menu @radix-ui/react-label @radix-ui/react-select @radix-ui/react-slot`
2. `rmdir src/components/ui`

### Phase 5 — Test sweep

- Run `npm test`. Fix breakage. Most failures will be:
  - Tests querying by class name → switch to role/label.
  - Tests doing `within(dialogContainer).getBy...` → use `screen.getByRole("dialog")` since Mantine portals to body.
  - Snapshot tests → regenerate if any exist.
- Click through each page manually via `npm run dev`. Note: this is a calorie tracker; main flows are Login → Diary → search/log food → view detail → edit/delete; also Meals CRUD, Admin pages.

## Risks and gotchas

- **`FoodLogEntry.tsx` (332 lines)** is the hardest file. It contains an inline edit form with multiple Selects, an Input, and Tailwind-heavy layout. Save for last.
- **Mantine v7 uses CSS modules**, not emotion. No `sx` prop — use `style={{}}` or component props. Don't follow MUI tutorials by mistake.
- **NativeSelect vs Select**: prefer `NativeSelect` wherever options are static and short — it's lighter, more native, and the user explicitly wants "native experience."
- **Portals**: Modal and Menu render outside the DOM tree of their trigger. Any test reaching into the trigger's parent won't find the content.
- **Forms**: shadcn relies on raw React state; Mantine has `@mantine/form` but **don't introduce it** — keep the existing `useState` patterns to minimize churn.
- **Don't theme Mantine.** The user wants the default look. Resist any urge to map old colors/radii into a `MantineProvider` theme. If something looks ugly, that's fine.
- **Don't refactor while migrating.** If you see code that could be improved, leave it. The goal is mechanical conversion. A separate cleanup pass can happen later.

## Definition of done

- `src/components/ui/` does not exist
- `grep -r "tailwind\|className=\"[a-z-]" src/` returns nothing Tailwind-flavored
- `package.json` has none of: `@radix-ui/*`, `tailwindcss`, `@tailwindcss/vite`, `tailwind-merge`, `clsx`
- `package.json` has: `@mantine/core`, `@mantine/hooks`
- `npm run build` succeeds
- `npm test` passes
- App boots and the major flows (login, diary view, log food, edit food log, meals CRUD) work end-to-end

## Notes for the executing agent

- Make a commit after **every** primitive replacement and after **every** page converted. Small commits make bisecting trivial if something breaks.
- If a Mantine component is missing a feature you had (e.g. a specific button hover effect), **skip it**. Native look is the goal.
- If you hit something genuinely blocking, stop and ask the user — don't invent workarounds that add complexity.
- The user works on this repo via Claude Code; they will review PRs, not micromanage. Aim for clean, readable diffs.
