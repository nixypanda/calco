# Structure-Matched Skeleton Loaders for CalCo

- **Status:** Final proposal (revised after architecture, layout and testing review)
- **Date:** 2026-11-09
- **Scope:** `frontend-web/` Elm 0.19.2 + elm-ui. Shell, route boot, page loading states, skeleton primitives and recipes, layout-stability testing.
- **Out of scope:** Visual redesign, new design tokens, replacing elm-ui, adding a browser-automation runtime dependency, changing route URLs or backend APIs. The only data-model changes are internal page state modelling needed to distinguish "pending" from "failed", and the route-plan refactor needed to keep pane geometry in one place.

## 0. What changed from the first draft

The first draft had the right diagnosis and the right testing direction, but several recipes and the no-jump contract were not true to the code. This revision:

1. Replaces the `round(fontSize * 1.5)` text-line guess with explicit `elLine` and `paragraphLine` geometry. elm-ui `Element.el` text is one font-size high; `Element.paragraph` defaults to `size + 5`. Known static copy is rendered as real text inside an `aria-hidden` skeleton subtree where that gives exact wrapping.
2. Redefines "no jump" as a **fixed envelope plus the first anchor before variable content**. It no longer promises stable top or height for save buttons, nutrition cards, footers, or fields below variable nutrient/component/list rows, optional categories, notes, or banners.
3. Removes `Page.Skeleton` as a second route table. `Page.elm` owns one route plan (`panePlanForRoute`) consumed by both `panesForRoute` and `bootstrapView`.
4. Defines the page skeleton public surface explicitly. Page modules expose `skeletonView`; the food and meal editor recipes live in `Component/FoodEditor` and `Component/Meal/Form`.
5. Rebuilds the Diary Day recipe from the real view: `totalsView` spacing 16, `calorieHero` spacing 12, a 40px status pill, 16px macro labels, 1px dividers, a 72px empty-slot block, prefs-driven slot count, and a `PrefsState` that distinguishes pending from failed.
6. Treats the Nutrition Details coverage banner as always present; fixes calendar cells to 68px **tall** and equal-width; splits Meal Show into its real section structure; documents the three portion controls on Food Show / Food Log Entry.
7. Corrects chrome/nav/scroll rules: the bottom nav is Phone-only, logout suppression is a real flag, and scroll reset keys off the rendered single-pane layout, not the device class.
8. Rewrites the browser harness: exact endpoints, staged `Fetch` interception, a deterministic date-gate seam, in-place skeleton markers, pane-scoped test ids, fixed-envelope versus anchor assertions, failure/empty/two-pane/narrow/update-banner cases, and a measurable CI promotion rule.

---

## 1. Executive Summary

CalCo already has a skeleton shimmer and page-local loading branches, but the skeletons mostly do not mirror the pages they replace, and the app hides the chrome when it is only waiting for a local date. The result is a visible snap on first paint, on date-gated routes, and on most edit/detail pages.

This proposal makes four bounded changes:

1. **Fix the shell first.** Keep the top bar mounted and 58px tall. Stop treating "waiting for today's date" as "hide the app chrome". Reserve the 56px bottom-nav space only on authenticated, non-admin Phone routes. Render the bootstrap skeleton inside the normal `Ui.Workspace` pane so gutter, max width and page rhythm match the loaded page.
2. **Add a small, exact primitive set to `Ui.Skeleton`.** The primitives mirror line boxes, `Ui.Page.pageHeaderRaw`, `Ui.Surface.section`/`panel`/`heroCard`/`listRow`, 44px controls, 118px hero media, chips, tables, stats and the calendar grid. Page-specific recipes stay with the page or component that owns the loaded structure. No `Ui` module imports `Page`, `View`, `Component` or route data.
3. **Use one route plan for pane shape.** `Page.panePlanForRoute` is the single source of truth for pane count, order and keys. `panesForRoute` consumes its `init`; `Page.bootstrapView` consumes its `skeleton`. This removes the manual "match the conditionals" step that would otherwise reintroduce the 1-pane/2-pane jump.
4. **Verify with a real browser.** `elm-test` is DOM-less and cannot measure layout. Add a Chrome DevTools Protocol layout harness, reusing the approach proven by `docs/scripts/capture-readme-screenshots.mjs`, that holds API responses, captures landmark boxes in loading and loaded states, and asserts the fixed envelope plus content anchors.

The work is deliberately incremental. The largest wins are Diary Day, the bootstrap/date-gate shell, and the three P0 edit pages. Every primitive lands with a real consumer. Phase 0-2 are report-only; blocking status is earned by a measurable green-run record.

### Success in one sentence

For the routes in the blocking matrix, the fixed shell, page frame, first surface/header band and first content anchor do not move between loading and loaded; content below the anchor is allowed to grow; every exception is named in the contract rather than hidden by a seed.

---

## 2. Problem Statement

### 2.1 Route transition lifecycle

There is no "keep the old page while the next one loads" state. A link pushes the URL (`frontend-web/src/Main.elm:139-155`); `UrlChanged` calls `changeRouteTo` synchronously (`Main.elm:149-155`, `376-395`), which calls `Page.initPreserving` (`Main.elm:389-395`). `Page.initPreserving` reconciles panes by key (`frontend-web/src/Page.elm:312-331`, `333-365`). Reused pane keys keep the same DOM and scroll; every new key is initialized immediately. Contextual routes may preserve an existing main pane on desktop through `contextualWorkspace` (`Page.elm:1242-1253`), but there is no cross-fade, no stale-page state, and no general DOM retention from the old route.

That means the loading state of the **new** page is the first thing the user sees. If it does not match the loaded structure, the page visibly reflows when the response arrives.

### 2.2 Two different meanings of "loading"

`Page.isLoading` is only `waitingForToday`:

```elm
-- frontend-web/src/Page.elm:160-162
isLoading model =
    model.waitingForToday
```

It does **not** mean a page fetch is in progress. Page-level loading is each page's own ADT (`Loading`/`Loaded`/`Failed`), and it is not visible to the shell. Only Diary Day, Calendar, Nutrition Details and Goals Settings require `today`; other routes create their panes immediately after bootstrap and show their page-local loading state.

`Page.loading` starts with `panes = []` and `waitingForToday = True` (`Page.elm:165-171`). `Main.init` uses it (`Main.elm:95-100`). Date-gated routes return `Nothing` from `panesForRoute` when `today` is missing (`Page.elm:883-999`), so `initPreserving` clears panes and sets `waitingForToday = True` (`Page.elm:313-331`). The flag is only cleared when a pane is reconciled (`Page.elm:382-410`).

Two consequences:

- **First paint:** `Main.pageView` renders `Skeleton.loading` while the session and bootstrap status are unresolved (`Main.elm:640-646`). The session is `Auth.Loading`, so `showsAppChrome` is false.
- **After bootstrap but before local date:** `Page.view` renders the same `Skeleton.loading` instead of `Workspace.view` (`Page.elm:3112-3120`).

Both are three full-width 16px bars (`Ui/Skeleton.elm:29-32`) rendered outside the workspace/page container. When the loaded pane appears, it snaps into the centered 960px column with a 16px Phone / 24px Tablet-and-up gutter (`Ui/Workspace.elm:55-70`).

### 2.3 Chrome hide/show

`Main.view` passes `Page.isLoading` as `isLoadingPage` (`Main.elm:519-575`). `Chrome.viewFrame` (in `frontend-web/src/Chrome.elm:126-193`, not `View.Chrome`) passes it to `showsAppChrome`. `showsAppChrome` returns false while the page is "loading" (`frontend-web/src/View/Chrome.elm:56-69`), so:

- the top bar swaps from the route title/profile chrome to a CalCo wordmark (`View/Chrome.elm:83-134`),
- the bottom nav disappears (`View/Chrome.elm:72-76`, `429-447`),
- the page's 56px bottom padding disappears (`Chrome.elm:201-218`).

The top bar is 58px in both branches, so the top bar itself does not change height. The real shell-level jump is that the page content loses its workspace gutter/max-width and the bottom-nav reservation during the date gate, while the top bar changes identity. On small screens this can also change the scrollable area and clamp document scroll.

The bottom nav is **Phone-only**: `Ui.Common.isSmall` is `device.class == Phone` (`Ui/Common.elm:13-15`). Tablet has no bottom nav and uses the 24px gutter.

This affects initial boot, auth reset/logout, and the date-gated routes: Diary Day, Calendar, Nutrition Details and Goals Settings.

### 2.4 Bare `Skeleton.loading`

`Skeleton.loading` is three 16px bars, spacing 12 (`Ui/Skeleton.elm:29-32`). It is used in two places:

- `Main.elm:640-646` before bootstrap;
- `Page.elm:3112-3120` while waiting for today.

It has no page header, no section shell, no list rows and no page-container rhythm. It is the single largest cause of the first-paint snap.

### 2.5 Page-local generic skeletons

Most pages already have a loading branch, but the branch is a generic stack of `Skeleton.input`, `Skeleton.card`, `Skeleton.listRow` and `Skeleton.button`. Concrete mismatches:

| Page | Current loading UI | Loaded structure it must mirror |
|---|---|---|
| Custom Food Edit | 4 `Skeleton.input` + button (`Page/CustomFood/Edit.elm:426-434`) | `FoodEditor.view`: basic info (name, brand, category block), N nutrient rows + hint + add footer, servings + add footer, default portion (responsive row/column) + hint, then save outside (`Component/FoodEditor.elm:1557-1565`, `1616-1890`, `1921-2140`; `Page/CustomFood/Edit.elm:392-414`) |
| Meal Edit | 4 inputs + card rows 3 + button (`Page/Meal/Edit.elm:506-515`) | Three `Surface.formSection`s / section (basic 2 fields, total 2 controls, components N custom rows + add footer), nutrition preview, save outside (`Component/Meal/Form.elm:358-412`, `652-707`; `Page/Meal/Edit.elm:467-497`) |
| Admin Edit User | card rows 5 + button (`Page/Users/EditUser.elm:459-462`) | Section header (display name + username), two detail rows, hairline, password field, reset button, separate bottom action (`Page/Users/EditUser.elm:326-406`) |
| Meal Show | card rows 2 + section + 3 rows + **three** cards + 2 buttons (`Page/Meal/Show.elm:715-731`) | Header `Surface.section` (notes body), separate components section with custom rows, nutrition `Surface.formSection` + preview, bottom actions (`Page/Meal/Show.elm:542-616`, `661-700`) |
| Food Show | 120px block + bars + 1 input + button + card rows 3 (`Page/Food/Show.elm:519-528`) | Column spacing 16, optional `lookup_note` banner, one `Surface.panel` with page header, optional category section, portion section with **three** controls, footer action, then nutrition card (`Page/Food/Show.elm:420-494`; `Component/FoodLogForm.elm:259-288`) |
| Custom Food Show | 120px block + bars + card rows 3 + 2 buttons (`Page/CustomFood/Show.elm:391-407`) | Page container, header section with page header + category row, nutrition card, 0 or 2 bottom actions (`Page/CustomFood/Show.elm:289-343`, `346-366`) |
| Food Log Entry | card rows 2 + 3 inputs + button + card rows 3 (`Page/FoodLog/Entry.elm:839-848`) | Column spacing 16, one panel with page header, optional category section, portion section with three controls, footer actions, then nutrition card (`Page/FoodLog/Entry.elm:524-619`; `Component/FoodLogForm.elm:259-288`) |
| Nutrition Details | 40px bar + stat card + 2 cards + card (`Page/NutritionDetails.elm:241-256`) | **Always-present** coverage banner, overview section, four variable nutrient sections, reference section (`Page/NutritionDetails.elm:259-285`, `380-413`) |
| API Keys | section-header button + 3 rows (`Page/Settings/ApiKeys.elm:453-462`) | Description paragraph above the section, then a section whose header is a full-width create button; rows with title + two subtitle lines + scope badge + revoke button (`Page/Settings/ApiKeys.elm:292-365`) |
| Goals Settings | header bar + 4 inputs + button inside section (`Page/Goals/Settings.elm:448-461`) | Section title 24 + description paragraph, 4 fields, save button **outside** the section (`Page/Goals/Settings.elm:319-413`) |
| Diary Settings | header bar + 4 generic bars + button (`Page/Diary/Settings.elm:235-247`) | Section title 24 + description paragraph, 5 checkbox rows at 44px, save outside (`Page/Diary/Settings.elm:157-222`) |
| Admin Dashboard | section header + 3 rows + footer button (`Page/Users/Dashboard.elm:138-146`) | Section title 24, rows with no leading dot, username title + display name, status badge, footer create button (`Page/Users/Dashboard.elm:89-124`) |
| Calendar | Month skeleton omits the weekday row and uses 2px gaps (`Page/Diary/Calendar.elm:331-346`; `Ui/MonthCalendar.elm:68-80`) | Weekday row, then 4-6 rows of **68px-tall, equal-width** cells with no inter-cell spacing (`Ui/MonthCalendar.elm:13-62`; `Page/Diary/Calendar.elm:326-371`) |

Existing primitive geometry is also off:

- `Skeleton.input` is an 80x12 label + 4px gap + **48px** field (`Ui/Skeleton.elm:71-90`). Real text controls are **44px** (`Ui/Input.elm:72-74`, `134-149`); a text input is label 13 + 44 with **no gap** because `Input.labelAbove []` adds no spacing. A dropdown is label 13 + 4px gap + 44 (`Ui/Input.elm:609-614`).
- `Skeleton.listRow` always has a 12x12 circle (`Ui/Skeleton.elm:105-133`). `Surface.listRow`/`staticRow` always reserve a 12px leading slot and use a 4x24 macro dot, no leading content, or a trailing chip/button (`Ui/Surface.elm:349-436`).
- `Skeleton.card` delegates to `Surface.card`, which already supplies **20px body padding and 12px spacing** (`Ui/Surface.elm:71-77`). It cannot reproduce a tinted header band, hairlines or a footer (`Ui/Surface.elm:215-297`); the draft's "no body padding" claim was wrong.
- There is no page-header skeleton, so the first block is usually a flat card.

### 2.6 Partial and asynchronous loads

Several pages render partially loaded data instead of a full-page skeleton:

- **Diary Day** has no loading skeleton at all. `contentView` always renders the real date card (`Page/Diary/Day.elm:515-599`). While loading it shows zero goals (`loadingGoalTargets`, `937-939`), zero totals and only sections with logs or enabled prefs (`956-984`). Meal-slot cards are `Surface.heroCard`s with a 118px media header (`1113-1136`; `DesignTokens.heroHeaderHeight = 118`, `Ui/DesignTokens.elm:34-36`). When data arrives, up to five large cards appear below the date card.
- **Diary Day** also loads prefs and latest slots independently (`Page/Diary/Day.elm:215-243`, `966-984`, `1026-1065`). Prefs determine which empty slots exist; latest slots only change the action label inside an existing empty slot.
- **Meal Show** loads the meal first, then requests component names and nutrition (`Page/Meal/Show.elm:150-162`, `340-365`, `368-381`). The component-name placeholder is a 16px `Skeleton.bar` in a row whose loaded text is a 16px `Typography.body` el line (`356-365`), so the row does **not** grow when the name arrives. Keep a 16px el line; do not replace it with a 24px guess.
- **Food Log Entry** has an in-page title bar until product detail arrives (`Page/FoodLog/Entry.elm:716-725`). The current bar is 16px, but the loaded title is `Typography.truncatedHeader`, a 24px paragraph with a 29px line box (`Ui/Typography.elm:135-146`), so this one **does** grow. Use a 29px paragraph line.
- **Food Search** has independent results, recents and barcode bodies (`Page/Food/Search.elm:1218-1261`, `1289-1290`, `1415-1416`).
- **Nutrition Details** always prepends a coverage banner (`Page/NutritionDetails.elm:259-285`); `coverageNotice` always returns `Feedback.warningBanner` or `Feedback.infoBanner` (`380-413`). Only the message and colour are conditional.
- **Meal Show** header body is the notes paragraph or `Element.none`; categories on Food Show/Food Log Entry are optional sections above the portion form.

### 2.7 Worst jumps

Ranked by visible reflow and frequency:

1. Diary Day (no skeleton; large hero cards appear).
2. App bootstrap / `waitingForToday` (3 bars vs full page; chrome swap).
3. Custom Food Edit.
4. Meal Edit.
5. Admin Edit User.
6. Meal Show.
7. Food Log Entry.
8. Food Show / Custom Food Show.
9. Nutrition Details (banner plus variable sections).
10. Admin Dashboard (admin landing page; currently close but wrong row geometry).
11. Food Search.
12. API Keys.
13. Goals Settings / Diary Settings.
14. Calendar.
15. List pages.

Priorities in §8 put Admin Dashboard at P1 even though it is not the largest jump, because it is the first page every admin session sees.

---

## 3. Goals, Non-Goals, and the Definition of "No Jump"

### 3.1 Goals

- Every page with a known route and a loading state renders a skeleton with the same **outer geometry** as the loaded page: same shell, same gutter, same max-width, same section/panel radius and padding, same header band height, and the same number and size of fixed controls.
- The top bar, bottom-nav reservation, workspace pane frame and page header do not move when a page transitions from loading to loaded, or when ordinary data fetches complete.
- The loading state is accessible, non-interactive and respects reduced motion.
- The layout contract is enforced automatically for the highest-risk routes, using a contract that is actually satisfiable for variable data.
- The change is incremental: each page can be migrated and shipped on its own, and every intermediate state is shippable.

### 3.2 Non-goals

- Redesigning the visual language, typography, colours, spacing scale or card styling.
- Replacing elm-ui, introducing a CSS framework, or adding a new npm runtime dependency.
- Eliminating all content movement. Variable-length content is allowed to grow below its anchor.
- Rendering real data in a skeleton, adding fake buttons/links, or delaying real responses to make skeletons last longer.
- Changing backend APIs, route URLs or data models beyond internal UI state needed to distinguish pending from failed.
- Route-to-route morphing/animation. A route change may replace the page body; the shell and the first page anchor must remain stable.

### 3.3 Precise definition of "no jump"

For a fixed route, viewport, theme, locale and deterministic data seed:

> The **fixed envelope** has the same viewport-relative border box in the loading state and the loaded state, within 1 CSS px on each compared axis. The **first content anchor before variable content** has the same x, y and width. Content below that anchor may change height. No document scroll clamp occurs during the transition. Pane count and pane column geometry do not change after session/date resolution.

This is deliberately narrower than "the whole page is identical". It is the only contract that survives real nutrient, component, log and user data.

#### Fixed envelope

Compare x, y, width and height:

- `app-topbar`: x=0, y=0, width=viewport, height=58.
- `app-bottom-nav`: x=0, width=viewport, height=56, bottom=viewport height, **only** on authenticated Phone routes that are non-admin and not `/login` or `/setup`.
- `page-root`: the `<main>` wrapper in `Chrome.viewFrame`; same x/y/width/height (height changes only if the nav reservation changes, which is excluded from loading→loaded comparison).
- `page-content`: the `Ui.Workspace` content root; same x/y/width (and height when the pane layout is fixed).
- `workspace-pane`: same visible pane count and same x/width for each visible pane. A pane's role (`main`/`detail`) is stable.
- `page-container` where the shared helper is used: same x/y/width.
- `page-header` / `surface-header`: same top/left/width. Header height is compared when the seed fixes the title and subtitle line count; otherwise height is a content-anchor property.
- `surface-0` for a route whose first surface is a header/date card: top/left/width. Height is compared only when the seed fixes all rows in that surface (Diary date card, Admin Edit details, Goals/Diary Settings form).
- `diary-date-card`: top/left/width/height for the seeded non-zero goal.
- `first meal-slot-card`: top/left/width; media header height 118.
- `calendar-weekdays`: top/height; `first calendar grid row`: top; every cell: height 68 and width ≈ gridWidth / 7 (or loading width equal to loaded width).
- `action-primary`: top/left/width/height 48 **only** on pages whose fixed row count and fixed description line count make it stable (Goals Settings with the seeded one-line status, Diary Settings with the static description, Admin Edit User with the seeded short username). It is not a general landmark.
- Fixed row heights where the seed fixes the row: Admin Dashboard rows, Admin Edit detail rows, API Keys rows.

#### Content anchors

Compare x, y and width only. Height is not compared because the content below is variable:

- the first list row (`list-row`), first result row, first component row, first nutrient row, first field/control row, first log row, first `stat`;
- the `nutrition-card` top, only in an explicitly marked "exact seed" case where the number of rows above it is fixed by the seed;
- the `action-primary` on pages with variable rows never appears in this class.

#### Explicitly variable (not part of the contract)

- the number of list/log/nutrient/component/calendar rows and months;
- the number of meal-slot cards when prefs are unknown;
- optional category sections, Meal Show notes, settings description wrapping, and other data/route-optional blocks;
- the coverage banner's line count (the banner shell is reserved; its text can be one or two lines);
- save buttons, nutrition cards, footers and fields **below** variable nutrient/component/list rows or optional category/notes blocks;
- long names, wrapped titles and chips that wrap;
- the document height below the first viewport;
- the update banner (see §7.5), unless both captures pin it identically.

#### Scope of the pane-count guarantee

- Before the session resolves, the app renders a **neutral boot shell**, not a route-specific skeleton. The body may change once when session/route resolution happens; the top bar, page frame and workspace gutter stay put.
- After the session and local date resolve, the pane count and pane x/width are stable for the routes in the matrix.
- Date-query contextual routes (`FoodSearch`/`FoodShow` with an explicit `date`) may add their diary/main pane once when `today` arrives on desktop. This is a deliberate, documented policy: the plan does **not** gate a usable search page behind the date port. The pane-count assertion for those routes starts after date resolution. If the product later requires an absolute no-pane-addition guarantee, the correct fix is to make the diary pane independent of `today` (or add a timeout-guarded gate), not to duplicate route conditions in a skeleton.

### 3.4 How the contract is applied per route

| Route group | Fixed envelope | First anchor before variable content | Never asserted below variable rows |
|---|---|---|---|
| Bootstrap / date gate | topbar, page-root, page-content, pane count, date card | first slot card top | slot count before prefs, first log row, add button |
| Diary Day | date card top/left/width/height (seed non-zero goal), first slot top, media 118 | first slot card top | first log row, add button, later slot tops |
| Calendar | month section top, weekday row top/height, first grid row top, cell height 68 / width ≈ grid/7 | first weekday label / first cell | month/row count, load-earlier button |
| Custom Food Edit | page-container/page-content, section 0 top, section 0 header band height, first field height 64 | first field top | category block, nutrient row, save, later fields below category/rows |
| Meal Edit | page container, basic section top/header band, first field height 64 | first component row top | save, nutrition preview, later sections |
| Admin Edit User | page container, section top/header band, first detail row height, password field 64 | first detail row top | nothing below fixed rows; bottom action is stable for the seed |
| Meal Show | page container, header section top/header band | first component row top (seed with no notes) | nutrition card, bottom actions, notes variant |
| Food Show / Food Log Entry | panel top/header band, title line | first control only in the seeded no-category variant | nutrition card, footer, category variant |
| Custom Food Show | page container, header section top/header band | header band content | nutrition card, action row |
| Nutrition Details | date header top/height, banner shell top/min height, overview section top | first nutrient section top only in the seeded coverage case | later sections, reference, long messages |
| Food Search | search controls top/height, results section top | first result row top | ad-hoc section, total page height |
| Goals / Diary Settings | page container, section top/header band (height when the description line count is fixed by the seed or is static) | first field/checkbox top when the description line count is fixed | save only in the seeded one-line description/fixed-row case; validation banners |
| API Keys | description top/height (seed locale), section top | first row top/height (seeded key) | row count, empty/non-empty height |
| Admin Dashboard | section top/header band | first row top/height | footer, user count |
| Lists | section top/header band | first row top/width | footer, row count, empty-state height |

The matrix in §8 repeats the route-specific acceptance in executable form. There must be no per-route claim that contradicts this table.

---

## 4. Design Principles

1. **A skeleton mirrors the final DOM, not an abstract notion of loading.**
   If the loaded page has a panel with a header band, a body and a footer, the skeleton uses the same `Surface.panel` shell with the same padding, radius, hairline and footer slots. Do not stack cards that do not exist.
2. **Reuse the production shells for geometry.**
   `Surface.section`/`panel`/`heroCard`/`card`, `Ui.Page.pageHeaderRaw`/`pageContainer`, `Ui.Workspace`, `Ui.MonthCalendar` and `Ui.Input` own padding, radius, gutter, header and control geometry. Skeleton recipes compose them rather than copy their numbers.
3. **Measure the real line box.**
   `Element.el` text is one font-size high; `Element.paragraph` defaults to `size + 5`. Use `elLine` and `paragraphLine`. Where the copy is static and known, render the real `Typography` text inside an `aria-hidden` skeleton wrapper; the browser then measures the same wrapping.
4. **The contract is an envelope plus an anchor, not whole-page equality.**
   Content below a variable block is allowed to move. Name the anchor and stop.
5. **One route plan.**
   Pane count, order, keys and skeleton bodies come from one `panePlanForRoute`. A second `case` over `Route` is a bug.
6. **Keep chrome mounted and height-stable.**
   The top bar is always 58px. The bottom nav is fixed 56px and its space is reserved only when the nav can render. Ordinary data fetches must not hide either.
7. **No fake interactivity.**
   Skeleton rows and buttons are `Element.el`/`Element.row`, never `Input.button`. Nothing in a skeleton is focusable, hoverable or clickable.
8. **Accessible by default, without claiming a disappearing node toggles state.**
   The persistent page root exposes `aria-busy`; the skeleton region exposes `role="status"` and one visually hidden label; decorative bars are `aria-hidden`.
9. **Gate if data is logically required; sub-skeleton if it is optional; never hide a failure.**
   Do not render a half-page with zero goals and then fill it. Do not replace an already-loaded page with a full-page skeleton for a retry/refresh. Do not use "pending" as a synonym for "failed".
10. **Land primitives additively.**
    Add new names with real consumers; do not change existing geometry globally in Phase 1.

---

## 5. Proposed API and Module Design

### 5.1 Layer and dependency graph

```
Main
 ├── Chrome / View.Chrome
 ├── Page ───────────────► Page.* modules
 │    ├── panePlanForRoute / panesForRoute / bootstrapView / bootShell
 │    └── Ui.Workspace, Ui.Skeleton
 └── View.* ─────────────► Ui.*
      ├── Ui.Skeleton ───► Ui.Page, Ui.Surface, Ui.Theme, Ui.DesignTokens, Ui.Common
      └── Ui.MonthCalendar ─► Ui.Skeleton
```

Rules:

- `Ui.Skeleton` may import `Element`, `Element.*`, `Ui.Page` (for `pageHeaderRaw`), `Ui.Surface`, `Ui.Theme`, `Ui.DesignTokens`, `Ui.Common`. It must **not** import `Page`, `View`, `Component`, `Data.Route`, `Data.MealSlot` or any page model. `Ui.Page` must not import `Ui.Skeleton`, so there is no cycle.
- Page-specific recipes (`Diary Day`, `Calendar`, `CustomFood Edit`, etc.) stay in the page module or in the component that owns the loaded structure. They may import data types and `Ui.*`.
- `View.Nutrients` owns the nutrition-card skeleton because it owns `nutritionCard` (`View/Nutrients.elm:553-564`).
- `Ui.MonthCalendar` owns the month-grid skeleton because it owns the grid and weekday row (`Ui/MonthCalendar.elm:13-80`).
- `Page.elm` owns the route plan and boot view. It already imports every page module (`Page.elm:34-74`) and owns `panesForRoute` (`Page.elm:883-999`). It does not import `Main` or `Chrome`.
- Page modules never import `Page` or a `Page.Skeleton` module. Only `Page.elm` calls page `skeletonView` functions. This keeps the graph acyclic.

Why `Page.elm` rather than `Page.Skeleton` or `Page.Bootstrap`:

- `Page.elm` already owns `paneKey`, `Pane`, `panesForRoute` and the contextual-pane helpers. A new module would either duplicate route conditions or need to import `Page` (cycle).
- The route plan is data, not a second view layer. Putting it next to the pane constructors makes the "shape and init move together" invariant obvious.
- The page module stays the owner of page-specific recipes; `Page.elm` only dispatches to `skeletonView`.

### 5.2 One source of truth for pane shape

Replace the current `panesForRoute` plus `contextualWorkspace`/`searchWorkspaceDesired`/`foodWorkspaceDesired` construction with one plan function. The sketch below is the intended shape, not final code:

```elm
-- Page.elm

type PaneKey
    = ReadyKey String
    | PendingTodayKey String

type alias PanePlan msg =
    { key : PaneKey
    , requiresToday : Bool
    , skeleton : Element msg
    , init : Maybe (() -> ( Pane, Cmd Msg, OutMsg ))
    }

panePlanForRoute :
    { today : Maybe LocalDate, existing : List Pane }
    -> Route
    -> List (PanePlan msg)
```

- `panePlanForRoute` is a single, exhaustive `case` over `Route`. `NotFound`, `Root` and every page constructor are listed explicitly; no catch-all.
- `key` is the eventual `paneKey` when computable. `PendingTodayKey` is explicit for an undated diary pane; it is not an accidental key.
- `skeleton` is the pane body in loading state. It is polymorphic `Element msg` and contains no page messages.
- `init` is `Just` for a pane that must be constructed. A preserved main pane uses `Just` with the existing pane; a skeleton-only boot does not need it.
- `requiresToday` marks routes that cannot build their pane without `today`. `panesForRoute` returns `Nothing` when any required `today` is missing; `bootstrapView` ignores `init` and still renders the skeletons.
- `panesForRoute` becomes a thin projection:

```elm
panesForRoute context generation existing =
    let
        plans =
            panePlanForRoute { today = context.today, existing = existing } context.route
    in
    if List.any .requiresToday plans && context.today == Nothing then
        Nothing

    else
        Just (List.map (planToDesired context generation) plans)
```

- The contextual rule lives in one helper and is reused by both the loaded pane list and the skeleton list:

```elm
contextualPlans existing fallbackMain detail =
    case List.head existing of
        Just pane ->
            if isMainPane pane then
                [ preservedPlan pane, detail ]

            else
                fallbackMain ++ [ detail ]

        Nothing ->
            fallbackMain ++ [ detail ]
```

This replaces `contextualWorkspace` and the duplicated `searchWorkspaceDesired`/`foodWorkspaceDesired` branches. `panePlanForRoute` decides once whether a route is contextual and what its fallback main is. `panesForRoute` uses `init`; `bootstrapView` uses `skeleton`.

Add one test that proves the shared shape: for a context with `today = Just date`, for every route, the keys from `panePlanForRoute` equal `Page.paneKeys` after `Page.init`; and for a date-query contextual route with `today = Nothing`, the shape is the immediate one-pane state and after `adoptToday` it is the two-pane state. Mutation: remove the contextual detail or reorder `fallbackMain`; the test fails. This is not a constructor-restatement test; it asserts the layout invariant across the route table.

### 5.3 Page skeleton public surface

Page skeleton functions cannot be private if `Page.elm` calls them. The public surface is:

| Module | Public function | Notes |
|---|---|---|
| `Page.Diary.Day` | `skeletonView : Env -> Maybe DiaryPrefs -> Element msg` | `Nothing` = neutral one-slot shell; `Just prefs` = exactly the enabled slots. The page's loading branch and `Page.bootstrapView` both call this. |
| `Page.Diary.Calendar` | `skeletonView : Env -> List String -> Element msg` | Empty list = one generic month shell for the pre-date boot. Non-empty = exact month labels, using `MonthCalendar.skeleton` with `monthRows`. |
| `Page.NutritionDetails` | `skeletonView : Env -> Element msg` | Date header shell + reserved banner shell + overview + four nutrient sections + reference. |
| `Page.CustomFood.Edit` | `skeletonView : Env -> Element msg` | Wraps `pageContainer` + `Component.FoodEditor.skeletonView` + save placeholder. |
| `Page.Meal.Edit` | `skeletonView : Env -> Element msg` | Wraps `pageContainer` + `Component.Meal.Form.skeletonView` + nutrition preview + save placeholder. |
| `Page.Meal.Show` | `skeletonView : Env -> Element msg` | Section detail recipe. |
| `Page.Food.Show` | `skeletonView : Env -> Element msg` | Panel detail recipe; render the route-known `lookup_note` banner if present. |
| `Page.FoodLog.Entry` | `skeletonView : Env -> Element msg` | Panel detail recipe with the 29px title line and Phone two-line subtitle. |
| `Page.CustomFood.Show` | `skeletonView : Env -> Element msg` | Header section + nutrition card + optional action placeholders. |
| `Page.Food.Search` | `skeletonView : Env -> Element msg` | Search controls shell + results section; recents/barcode are in-place. |
| `Page.Goals.Settings` | `skeletonView : Env -> Element msg` | Section header + 4 fields + save outside. |
| `Page.Diary.Settings` | `skeletonView : Env -> Element msg` | Section header + 5 checkbox rows + save outside. |
| `Page.Settings.ApiKeys` | `skeletonView : Env -> Element msg` | Description + section with create-button header + 3 rows. |
| `Page.Users.EditUser` | `skeletonView : Env -> Element msg` | Section + detail rows + reset block + bottom action. |
| `Page.Users.Dashboard` | `skeletonView : Env -> Element msg` | Admin list section. |
| `Page.CustomFood.List` | `skeletonView : Env -> Element msg` | List section with two header buttons. |
| `Page.Meal.List` | `skeletonView : Env -> Element msg` | List section with one header button. |
| `Component.FoodEditor` | `skeletonView : Env -> Element msg` | Owns the editor's section furniture: basic info/category block, nutrient section, servings, default portion. |
| `Component.Meal.Form` | `skeletonView : Env -> Element msg` | Owns the three meal form sections and component rows. |
| `View.Nutrients` | `skeletonCard : Theme -> Element msg` | Replaces/absorbs `skeletonPreview`; `preview` calls `skeletonCard` so both paths share one card skeleton. |
| `Ui.MonthCalendar` | `skeleton : Theme -> { period : Maybe String, rows : Int, cellHeight : Int } -> Element msg` | Weekday row + rows. When `period` is `Just`, the skeleton derives its row count from the shared `monthRows period`; the `rows` field is only the generic pre-date fallback. Both `MonthCalendar.view` and the period-known skeleton call the same `monthRows`. |

Every skeleton function is polymorphic `Element msg` (no `Page.Msg`). That keeps `Page.bootstrapView` polymorphic, so `Main.pageView` does not need a second `Element.map` for skeleton content. The page's own loading branch calls the same function; parameter differences are model-derived values, not a private second implementation.

`Page` also exposes a small `isBusy : Model -> Bool` for the persistent `aria-busy` root. It is true when `waitingForToday` or when a mounted pane's page-level state is `Loading`/`NotAsked`. Implement it by pattern-matching the pane models in `Page.elm`, or by adding a tiny `isLoading : Model -> Bool` to the page modules whose models are opaque. Test usage is accepted by the default `NoUnused.Exports` rule; a production caller is `Main.view`.

`skeletonView` returns the page-shaped body, not the status wrapper. The page's own loading branch and `Page.bootstrapView` each wrap that body in exactly one `Skeleton.busy`; this keeps the "one status per page pane" rule in one place. In-place sub-skeletons never use `Skeleton.busy`.

For pages whose skeleton needs a known route parameter (Diary prefs, Calendar months), the parameter is explicit as above. Do not keep a private `calendarSkeleton`/`mealShowSkeleton` that duplicates the public one.

### 5.4 Primitive additions

All signatures below are proposed public API. Inline record types avoid new exposed type aliases and `NoMissingTypeExpose`. No new union types are needed in `Ui.Skeleton`; internal ADTs (`PrefsState`, `PaneKey`) are allowed elsewhere.

Land each primitive in the same change as its first real consumer. Test-only use is acceptable when justified; see §5.6. Do not add the whole table up front.

| Primitive | Signature | Geometry / use |
|---|---|---|
| `elLine` | `elLine : Theme -> { size : Int, width : Element.Length } -> Element msg` | A bar exactly `size` px high. Mirrors `Element.el` + `Typography` text lines: 13 (caption), 16 (body), 20 (screen/subsection), 24 (section/title), 32 (page title), 44 (hero stat). |
| `paragraphLine` | `paragraphLine : Theme -> { size : Int, spacing : Int, width : Element.Length } -> Element msg` | A bar exactly `size + spacing` px high. Default elm-ui paragraph spacing is 5, so 16 -> 21, 24 -> 29. This models a line plus one inter-line gap; a **single-line** 16px paragraph measures ~17px (Admin Edit uses `elLine 17`). Prefer `paragraphLine` for multi-line/list titles and `truncatedHeader`. |
| `icon` | `icon : Theme -> Element msg` | 44x44, radius 999. Mirrors `Button.iconButton` (`Ui/Button.elm:390-403`). |
| `dot` | `dot : Theme -> Element msg` | 4x24, radius 2. Mirrors `Surface.accentDotLabeled` (`Ui/Surface.elm:451-462`). |
| `chip` | `chip : Theme -> Element msg` | Height 22, width 64, radius 999. Mirrors `.ui-chip` (`frontend-web/src/main.css:174-191`). |
| `chipRow` | `chipRow : Theme -> { count : Int } -> Element msg` | Row with 4px gap, N category chips. For category rows, compose the leading ghost dot separately: `Element.row [ spacing 12 ] [ dotGhost, chipRow ... ]` (`View/Product.elm:56-64`). |
| `pageHeader` | `pageHeader : Theme -> { leading : Maybe (Element msg), title : Element msg, subtitle : List (Element msg), actions : List (Element msg) } -> Element msg` | Delegates to a new `Ui.Page.pageHeaderRaw` that owns the `wrappedRow` width fill, spacing 12, min-width 0, title column spacing 4 and actions row spacing 8. `pageHeaderRaw` always renders the leading and actions slots (even when `Nothing`/empty) so the title x matches. `Ui.Page.pageHeader` maps its `PageHeaderSubtitle` to elements and calls the same raw helper. |
| `field` | `field : Theme -> { labelWidth : Element.Length, gap : Int } -> Element msg` | `elLine 13` label + `gap` + 44px control, radius 12. Use gap 0 for text inputs (`Ui/Input.elm:134-149`) and gap 4 for dropdowns (`Ui/Input.elm:609-614`). Existing `input` stays at 48px until its call sites migrate. |
| `checkboxRow` | `checkboxRow : Theme -> Element msg` | 44px row: 28px circle + 12px gap + 16px title line. Mirrors `Ui/Input.checkbox` (`Ui/Input.elm:655-671`). |
| `stat` | `stat : Theme -> Element msg` | Min width 130, padding 12, three paragraph lines (18 / 21 / 18) with 2px spacing. Mirrors `Page/NutritionDetails.overviewItem` (`Page/NutritionDetails.elm:315-333`); the third line is reserved so the common partial-coverage case is covered. |
| `table` | `table : Theme -> { rows : Int } -> Element msg` | Header row + `rows` data rows, three columns: fill line, right-aligned amount line, unit line. Row height 32 (16 + 8 top + 8 bottom). Mirrors `View.Nutrients.nutrientsTableInner` (`View/Nutrients.elm:483-546`), which includes a header row. |
| `bottomActions` | `bottomActions : Theme -> { count : Int } -> Element msg` | N full-width 48px buttons; row for 2, column for others. Mirrors `Button.bottomActionButtons` (`Ui/Button.elm:294-332`). |
| `busy` | `busy : { label : String } -> List (Element msg) -> Element msg` | Root wrapper with width fill, `role="status"`, one visually hidden label, and `aria-hidden` on decorative children. No `Theme` parameter is needed; `NoUnused.Parameters` would fail on it. Do not put `aria-busy` here; it belongs on the persistent page root. |
| `row` | `row : { leading : List (Element msg), title : Element msg, subtitle : List (Element msg), trailing : List (Element msg) } -> Element msg` | New additive row primitive that delegates to `Surface.staticRow` (`Ui/Surface.elm:375-389`). `title` is `Element msg`, not `Element.Length`; callers pass `paragraphLine 16` (21px) for list titles because the loaded title is a paragraph. Existing `listRow : Theme -> Element msg` stays unchanged until its call sites migrate. |

Deliberately omitted:

- **`media`**: no real consumer. The Diary recipe uses `Surface.heroCard` directly with its `mediaHeader` API (`Ui/Surface.elm:102-163`).
- **`section` / `panel` aliases**: recipes call `Surface.section`/`Surface.panel` directly with skeleton content. A thin alias adds API surface without geometry.
- **`rect` / `toggle`**: `barCustom`, `dot`, `icon`, `chip`, `field` and `checkboxRow` cover the matrix. Add only with a caller.
- **Calendar weekday row**: it lives in `Ui.MonthCalendar.skeleton`, next to `equalColumn` and the loaded weekday row, to avoid duplicating the 7-column geometry.

Existing primitives:

- Keep `bar`, `barCustom`, `button`, `card` for current call sites.
- Keep `input` and `listRow` unchanged in Phase 1. Add `field` and `row` with their first consumers. Delete the old names only when the last call site migrates.
- Remove `loading` after its two call sites are migrated (`Page.elm:3115`, `Main.elm:643`) and both boot paths use `bootShell`/`bootstrapView`.
- `Skeleton.card` already has 20px body padding and 12px spacing via `Surface.card`; use it for card-shaped regions, not for panel/detail structures.

### 5.5 `pageHeaderRaw` and the real/skeleton header share

Add `Ui.Page.pageHeaderRaw` with the same geometry as `pageHeader`, but accept concrete elements:

```elm
pageHeaderRaw :
    Theme
    -> { leading : Maybe (Element msg)
       , title : Element msg
       , subtitle : List (Element msg)
       , actions : List (Element msg)
       }
    -> Element msg
```

The real `pageHeader` maps `SubtitleText` to `mutedBody` (16px el), `SubtitleMeta` to one 21px paragraph, and `SubtitleMetaLines` to a spacing-2 column of 21px paragraphs, then calls `pageHeaderRaw`. The skeleton passes `paragraphLine`/`elLine` elements of the same shape. This prevents the real and skeleton headers from drifting, and preserves the empty leading slot that keeps the title x stable.

Do not expose `titleSize`/`subtitleLines` as the only knobs: the title may be an `Element.el` 24px line or a `truncatedHeader` 29px paragraph, and the subtitle may be a 16px el, one 21px paragraph, or two 21px paragraphs on Phone.

### 5.6 elm-review constraints and phasing

`elm-review` enforces `NoUnused.Exports`, `NoUnused.Modules`, `NoMissingTypeAnnotation`, `NoMissingTypeExpose`, `NoExposingEverything`, `NoImportingEverything`, `NoUnused.Parameters`, `NoUnused.CustomTypeConstructors` and `NoUnused.CustomTypeConstructorArgs` (`frontend-web/review/src/ReviewConfig.elm:30-78`).

Practical rules:

- The repo uses the default `NoUnused.Exports.rule` (`ReviewConfig.elm:67`). It reports exports that are not used anywhere in the project; **test usage counts**, and `reportUnusedProductionExports` is not enabled. Land each primitive with a real consumer (production preferred; a justified test is acceptable). Do not base the phasing on a false "production-only caller" rule.
- Internal ADTs such as `PrefsState` and `PaneKey` are allowed. `NoUnused.CustomTypeConstructors`/`Args` requires every constructor and argument to be used; they are.
- Every top-level value and let binding needs a type annotation (`NoMissingTypeAnnotation`, `NoMissingTypeAnnotationInLetIn`).
- No unused function parameters (`NoUnused.Parameters`), hence theme-free `busy`.
- Keep lines ≤100 columns. `justfile:149-154` checks with `rg -n '.{101,}'`; the target is 100, not the draft's 149-155 claim. `check-frontend` is at line 144.
- New `src/Ui/*.elm` files are auto-discovered, but must be imported in production or `NoUnused.Modules` fails. Do not create a speculative module.
- Do not change `paneKey` to encode loading state. A key change remounts the pane and destroys its DOM and scroll (`Page.elm:205-284`).
- Update `docs/frontend.md` with the `Page.elm` route-plan exception, `Ui.Skeleton → Ui.Page` direction, and the boot shell. Add the harness to `docs/testing.md` and the QA steps to `docs/qa-runbook.md`.

---

## 6. Shared Layout Recipes

Each recipe names the loaded DOM it mirrors, the shells/primitives it reuses, what may legitimately grow, and the stable landmarks. The line model from §5.4 applies everywhere: `elLine size` = `size` px; `paragraphLine size` = `size + 5` px unless another paragraph spacing is explicit. A single-line paragraph is closer to `elLine size` (~17px for 16px) than to `paragraphLine 16/5`.

### 6.1 List section

**Loaded structure:** either a page container/column later described by the page, then a `Surface.section` whose header is a full-width create button (Meal List, Custom Food List) or a section title (Admin Dashboard), a body of N `Surface.listRow`s separated by `Surface.hairline`, and optionally a footer button (Admin Dashboard). References: `Page/CustomFood/List.elm:114-136`, `Page/Meal/List.elm:108-141`, `Page/Users/Dashboard.elm:89-124`.

**Recipe:**

- Same page wrapper and spacing as the loaded page:
  - Custom Food List / Meal List: `Element.column [ width fill, spacing 16 ]` with an optional error banner, then the section. No `pageContainer` in the loaded page.
  - Admin Dashboard: a single `Surface.section`; no page container.
- `Surface.section`:
  - header: a 48px `Skeleton.button` for a full-width create button; two side-by-side 48px buttons for Custom Food List; `elLine 24` for Admin Dashboard's section title.
  - body: 3 `Skeleton.row`s with the loaded leading:
    - foods/meals: `macroDot` 4x24 in the 12px leading slot;
    - admin users: `leading = []` (the `Surface.listRow` still reserves the 12px slot, so the skeleton must too);
    - titles: `paragraphLine 16` because `Typography.wrappedListItemTitle` is a paragraph (`Ui/Typography.elm:112-115`);
    - subtitles: `paragraphLine 16` for one body line, plus `paragraphLine 16` + `paragraphLine 13` where loaded; custom foods add a chip row; admin users add a trailing status badge 21px.
  - Intersperse `Surface.hairline` between rows where the loaded page does (Custom Food List, Meal List); Admin Dashboard does not.
  - footer: `Skeleton.button` only when the loaded page puts the action in the footer (Admin Dashboard).
- Do not add a second fake header button. Custom Food List has two header buttons; mirror both only there.
- Empty state: the loaded body becomes one `Typography.mutedBodyParagraph`, not 3 rows. The loading skeleton may show 3 rows; the loaded empty page is allowed to shrink below the first row. Add an empty case in the harness that asserts the section top and the `empty-state` presence, not a first row.

**May grow:** number of rows, row text wrapping, chips, footer position.
**Stable:** page wrapper (where present), section top/left/width, header band height, first row top/left/width; row height only for a fixed seed.

### 6.2 Panel detail: Food Show and Food Log Entry

**Loaded structure:** `Element.column [ width fill, spacing 16 ]` containing an optional error banner, an optional route-known `lookup_note` info banner (Food Show), one `Surface.panel`, and a nutrition card. The panel header is `View.Product.foodHeaderElement` or `Page/FoodLog/Entry.itemHeaderElement`: a `Ui.Page.pageHeader` with a macro dot, a `truncatedHeader` 24px paragraph (29px line), and a subtitle. Sections:

1. optional category section (body: `Element.row spacing 12 [ macroDotGhost, Chip.chips ]`);
2. portion section: title `subsectionTitle` 20px, body exactly `FoodLogForm.fields` — **three controls**: meal-slot dropdown, quantity/unit dropdown, notes input;
3. footer: full-width submit button 48px.

Then `View.Nutrients.nutritionCard`.

References: `Page/Food/Show.elm:420-494`; `Page/FoodLog/Entry.elm:524-619`; `Component/FoodLogForm.elm:259-288`; `View/Product.elm:36-64`.

**Recipe:**

- Same wrapper as loaded: Food Show/Food Log Entry use their own column spacing 16, not `pageContainer`. Get the root column right; a `page-container` is optional and must not be invented.
- If the route carries `lookup_note`, render the real info banner in the skeleton; it is known synchronously from `Route` (`Data/Route.elm:33`, `78-84`). Otherwise no banner.
- `Surface.panel`:
  - header: `Skeleton.pageHeader` with `leading = Just (Skeleton.dot)`, `title = paragraphLine 24` (29px), `subtitle`:
    - Food Show: one `paragraphLine 16` (21px) for `SubtitleMeta`;
    - Food Log Entry: one on Desktop/Tablet, two `paragraphLine 16` (21px each) plus a spacing-2 column on Phone, matching `SubtitleMetaLines` and the two-line fallback (`Page/FoodLog/Entry.elm:737-770`).
  - category section: **do not invent a category row in the generic skeleton**. Categories are optional and unknown while loading. The skeleton represents the no-category case; a food with categories pushes the portion section down. This is explicitly variable. If the product wants no movement for a known seed, add an exact-seed variant, not a general claim.
  - portion section: title `elLine 20` (20px) and three controls:
    - meal slot dropdown: label 13 + gap 4 + 44px trigger = 61px;
    - quantity/unit dropdown: 61px;
    - notes text input: label 13 + 7 gap + 44px = 64px;
    - the panel body column spacing 12 separates them.
  - footer: full-width `Skeleton.button` 48px.
- `View.Nutrients.skeletonCard` after the panel. Card header `elLine 20`, macro row, hairline, table header and 6 rows.
- Do not use the draft's "two fields" recipe. There are three controls.

**May grow:** category section, wrapped title/subtitle, nutrition rows, notes.
**Stable:** panel top/left/width, panel header band top/height, title line top when the seed fixes the title, first control top only in the seeded no-category variant. **Not stable:** first control across category variants, footer, nutrition card.

### 6.3 Section detail: Meal Show

Meal Show is not a panel. `MealShow.view` is a `pageContainer` containing a header `Surface.section`, then a `loadedView` column spacing 16 with a components section, a nutrition column, and bottom actions (`Page/Meal/Show.elm:542-700`).

**Recipe:**

- `pageContainer` with the same spacing 16.
- Header `Surface.section`:
  - header: `Skeleton.pageHeader` with `leading = Just (Skeleton.dot)`, `title = paragraphLine 24` (29px), `subtitle = []` (the loaded header has **no subtitle**), `actions = []`.
  - body: `Element.none` to match the loaded `[ Element.none ]` when there are no notes. This still creates the 20px-padded body region that the loaded page has. If the seed has notes, the loaded body grows by paragraph lines; notes are variable. Do not promise the components section top across notes variants.
- Components `Surface.section`:
  - header: `elLine 20` (`subsectionTitle`);
  - body: 2 custom component rows with `Surface.hairline` interspersed. A component row is `Element.row [ width fill, spacing 12 ]` with a 12px leading slot (4x24 macro dot or empty), then a column spacing 4 with a 16px name el line and a 16px quantity el line. It is not `Surface.listRow`; do not use the list-row padding.
- Nutrition column `Element.column [ width fill, spacing 12 ]`:
  - `Surface.formSection` title 20 with a 61px quantity/unit dropdown;
  - `View.Nutrients.skeletonCard` (the loaded preview is `View.Nutrients.preview`, which wraps `nutritionCard`).
- Bottom actions: `Skeleton.bottomActions { count = 2 }` (row of two full-width 48px buttons).
- The loaded bottom actions are below the variable component/nutrition content; their top is not stable.

**May grow:** notes, component count, component names, nutrition rows.
**Stable:** page container, header section top/header band, first component row top in the seeded no-notes case, component row height for a fixed seed. **Not stable:** nutrition card, bottom actions.

### 6.4 Settings forms

There are three different furniture patterns:

- **Goals Settings:** `pageContainer` → optional error banner → `Surface.section` whose header is `Surface.sectionHeader` (title 24 + description paragraph 21) → body of 4 numeric text fields (label 13 + 7 gap + 44 = 64) → save button **outside** the section (`Page/Goals/Settings.elm:319-413`).
- **Diary Settings:** `pageContainer` → `Surface.section` with title 24 + description paragraph (1-2 lines) → body of 5 `Ui.Input.checkbox` rows at 44px → optional error banner → save button **outside** (`Page/Diary/Settings.elm:157-222`).
- **API Keys:** `pageContainer` → description `mutedBodyParagraph` above the section → `Surface.section` whose header is a full-width create button → body of rows (`Surface.staticRow`) with title 21, subtitle body paragraph 21 + caption paragraph 18, trailing scope badge 21 and revoke button 48; empty state is one paragraph (`Page/Settings/ApiKeys.elm:292-365`).
- **Admin Edit User:** `pageContainer` → optional error banner → `Surface.section` whose header is a column title 24 + username paragraph 17 → body of two detail rows, hairline, then a reset block (title paragraph 17 + password field 64 + 48px button) → separate bottom action 48 outside (`Page/Users/EditUser.elm:279-406`).

**Recipe:**

- Same `pageContainer` and same section wrapper.
- Header geometry depends on the loaded helper:
  - `Surface.formSection` uses `subsectionTitle` 20 and no description (`Ui/Surface.elm:344-346`). Use it for the editor sections, not for Goals/Diary Settings.
  - `Surface.sectionHeader` uses `sectionTitle` 24 plus an optional description (`Ui/Surface.elm:324-341`). Use 24 + 16 paragraph for Goals/Diary Settings/Admin Edit.
- Render static descriptions as real `Typography.mutedParagraph`/`mutedBodyParagraph` text inside the skeleton's `aria-hidden` subtree. They are known from i18n; this gets the exact phone wrap (API Keys is ~2 lines at 390; Diary Settings 1-2). A single `elLine 16` is wrong.
- Fields: `field { labelWidth, gap = 0 }` for text inputs; `gap = 4` for dropdowns. Do not use the old 48px `input`.
- Checkbox rows: 5 rows for Diary Settings, because the loaded page always maps `MealSlot.all`.
- Admin Edit User: two detail rows (`caption 13` label + chip 21/caption 13 value), hairline, reset block with password field, bottom action outside.
- Save placement: outside the section for Goals/Diary Settings; outside the section for Admin Edit bottom action; no footer for API Keys.
- Empty API Keys: body is a paragraph; section top/header still stable. Add an empty state case.

**May grow:** validation banners, description wrapping (static but locale/device), nutrient/component rows (not these settings pages), API key row count.
**Stable:** page container, section top/header band, first field/checkbox row top when the description line count is fixed (Goals' status message is data-derived; render the real static Diary Settings description and assert exact wrapping there), save top only in the seeded one-line-description/fixed-row case, bottom action top for Admin Edit (fixed rows, seeded short username). **Not stable:** save below any variable rows or a multi-line status/validation banner; API Keys footer (there is none) / row count.

### 6.5 Diary Day

**Loaded structure:** `contentView` is a column spacing 16 with the real date card, then either an error banner (`diary = Failed` for the current date) or `logGroupsView` (`Page/Diary/Day.elm:515-542`).

Date card (`Surface.section`, `545-599`):

- header row spacing 12: previous icon 44x44, centered `sectionTitle` 24 (date), next icon 44x44;
- body `totalsView` is a **column spacing 16** (`602-634`):
  - `calorieHero` is a **column spacing 12** inside (`651-723`): a row spacing 12 with a column spacing 2 [caption 13, `heroStat` 44, body 16], and a status pill `paddingXY 16 12` + body 16 = **40px** high (not 48);
  - progress bar 12px;
  - if target > 0, a right-aligned body 16 line ("of kcal"); if target = 0, this line and the pill are omitted;
  - hairline;
  - macro row spacing 8 with 1px dividers: each item is a column spacing 8 [label **body 16** bold, value body 16 bold, progress bar 8] (`726-763`);
  - `detailsAction` full-width 48px button.

Meal slots (`956-1220`):

- `logGroupsView` maps `MealSlot.all`, filters with `shouldShowSection` (logs present or prefs enabled), and appends an unslotted `Nothing` section if there are unslotted logs.
- For `Just slot`, `Surface.heroCard` with media height 118, `fade = True`, content padding top 38 / bottom 20 / left and right 16 (Phone) or 34 (wider), and a header row padding 12 spacing 12 [column spacing 4: `sectionTitle` 24 + caption 13 macro summary; caption 13 kcal].
- Body: `Surface.hairline`, then either:
  - logs: `logRow`s (`Input.button`, width fill, padding 12, row spacing 12 [macro dot 4x24, `wrappedListItemTitle` paragraph 21, trailing caption 13 quantity + caption 13 kcal]);
  - empty slot: `emptySlotView` = `Element.el [ width fill, padding 12 ]` around a 48px text button, i.e. a **72px block** (`1026-1070`);
  - then `Surface.hairline` and a full-width 48px add-food button.
- For `Nothing`, `Surface.section` with the same header and only log rows.

**Recipe (`Page.Diary.Day.skeletonView : Env -> Maybe DiaryPrefs -> Element msg`):**

- Same column spacing 16. Do not add `pageContainer`; the loaded page does not use it.
- Date card skeleton via `Surface.section` with the same header/body shells:
  - header row: `Skeleton.icon` 44, `elLine 24` width 160 centered (or the real date text), `Skeleton.icon` 44;
  - body spacing 16: a row spacing 12 with a column spacing 2 [caption 13 line, hero stat 44 line, body 16 line] and a 40px status pill; a 12px progress bar; a right-aligned body 16 line; hairline; macro row spacing 8 with three columns (label real text 16, value 16, bar 8) and 1px dividers; 48px button.
  - The date-card height is compared only for the seeded non-zero goal. A zero-goal user omits the pill and "of kcal" line; that is a product/data variant, not a skeleton-only fix. Either document it as variable or make the loaded zero-goal date card reserve the same space (a product decision).
- Slots:
  - `Nothing` prefs: one **neutral slot shell** — a single `Surface.heroCard`-shaped block with a 118px media header and one 72px empty-slot body block. Do not render five full cards. The slot count is unknown and variable.
  - `Just prefs`: render exactly `MealSlot.all |> List.filter (DiaryPrefs.isEnabled slot)`; do not use a fixed 5. For each enabled slot that has no known logs (the page is still loading), use the **empty-slot geometry**: media header 118, header row as loaded, hairline, a 72px empty-slot block, hairline, 48px add button. Do not use one log row as an approximation.
  - If logs were already known (`diary = Loading { logs = Just ... }`), gating on `diary == Loading` hides them until loaded; that is acceptable: the page transitions once from skeleton to the loaded body. Do not render a partial body with zero goals.
- Gate on **pending**, not failure:
  - add `PrefsState = PrefsLoading | PrefsLoaded DiaryPrefs | PrefsFailed ApiError` (or an equivalent internal ADT);
  - evaluate failure first: `diary = Failed` renders the real date card + `Feedback.errorBanner`, never a skeleton;
  - otherwise `isPageLoading = diary == Loading || prefs == PrefsLoading`;
  - on `prefs = PrefsFailed`, do not leave a permanent skeleton: once the diary is loaded, render the date card + a non-blocking warning + the sections with logs (no enabled empty slots, because prefs are unknown).
- `latestSlots` only changes the empty-slot button label/disabled state and does not change row height (`Day.elm:1026-1065`), so it needs no skeleton.
- The add-food button top and first log row are **not** stable when the skeleton uses the empty-slot block and the loaded slot has logs. Do not assert them.

**May grow:** number of enabled slots after prefs resolve, logs per slot, names, macros wrapping.
**Stable:** column top/left/width, date card top/left/width/height (seed non-zero goal), first slot card top/left/width, media header height 118. **Not stable:** slot count before prefs, first log row, add-food button, later slot tops.

### 6.6 Calendar month

**Loaded structure:** `contentViewWithSelection` is a column spacing 16 with one `Surface.section` per month plus a full-width "load earlier" button (`Page/Diary/Calendar.elm:288-314`). Each month section has a 24px title and a `MonthCalendar.view` body: a weekday row, then 4-6 rows of **68px-tall, equal-width** cells with no inter-cell spacing (`Ui/MonthCalendar.elm:13-62`; `Page/Diary/Calendar.elm:326-371`).

**Recipe (fix the existing `calendarSkeleton`/`monthSkeleton`):**

- Keep the same month count from `monthRange model.newestMonth model.oldestMonth` (`Page/Diary/Calendar.elm:317-335`).
- `monthSkeleton`: `Surface.section` with a real month label or `elLine 24` header; body = `MonthCalendar.skeleton`.
- `MonthCalendar.skeleton`:
  - add a weekday row of 7 equal columns using the real weekday labels (static, `Typography.caption` 13) or `elLine 13`;
  - outer column `spacing 8` between the weekday row and the grid, matching `Ui/MonthCalendar.elm:46`;
  - grid rows use `Element.row [ width fill ]` with **no spacing**, and the grid column has no spacing (`Ui/MonthCalendar.elm:44`, `61`);
  - each cell uses `Element.width (Element.fillPortion 1)`, `equalColumn` (`flex: 1 1 0; min-width: 0`), and height **68** (`Page/Diary/Calendar.elm:326-328`);
  - remove the current `space2` row/column gaps (`Ui/MonthCalendar.elm:78-80`), keep the outer 8px rhythm;
  - extract `monthRows : String -> List (List (Maybe Int))` and use it from both `view` and the period-known `skeleton` so row count cannot drift.
- Keep the trailing 48px load-earlier button.
- For the pre-date boot, `Calendar.skeletonView env []` renders one generic month shell with a title bar and 5 rows (`period = Nothing`); month count and rows are variable. For the page's own loading branch, pass the exact month labels as `period = Just month`, so the same `monthRows` drives the skeleton.

**May grow:** number of months loaded, month row count (4/5/6).
**Stable:** first month section top, weekday row top/height, first grid row top, cell height 68, cell width ≈ gridWidth/7, no horizontal overflow. **Not stable:** month count, load-earlier top.

### 6.7 Bootstrap and route boot

**Pre-session:** `Main.pageView` uses `Page.bootShell env`: one neutral `Ui.Workspace` pane inside the normal page frame, with a generic page-header line and a generic section shell. It does **not** guess Diary, Admin or Login. The top bar stays 58px (wordmark branch while `Auth.Loading`), the workspace gutter/max-width are present, and the bottom nav is absent because the session is not authenticated.

**After session, before local date:** `Page.view env route model` checks `model.waitingForToday` and renders `Page.bootstrapView env route`, which wraps the route-specific plan skeletons in `Ui.Workspace`. This is the same function used by the first paint after bootstrap, so the date-gate frames cannot drift.

**After both resolve:** `Page.view` renders the real panes through `Ui.Workspace`.

`Page.bootstrapView`:

```elm
bootstrapView env route =
    Workspace.view env.device
        (panePlanForRoute { today = Nothing, existing = [] } route
            |> List.map (\plan -> ( paneKeyString plan.key, Skeleton.busy { label = ... } [ plan.skeleton ] ))
        )
```

- `panePlanForRoute` is the same plan used by `panesForRoute`; there is no second route table.
- Each visible pane gets one `Skeleton.busy` status region. On desktop two-pane routes, two status regions are correct because two panes are independently loading.
- `Root` and `NotFound` use a neutral plan; do not prescribe the Diary skeleton for `Root`. `Access.resolveKnownSession` maps `Root` to `AdminDashboard` for admins, `AuthLogin` for unauthenticated users, and `DiaryDay` for non-admin authenticated users (`Access.elm:23-70`). Pre-session the app cannot know which.
- Auth login/setup pages are synchronous credential forms; after boot they need no page skeleton. Pre-bootstrap they get the neutral boot shell.
- Routes with no page fetch (`AdminCreateUser`, `SettingsApiKeyCreate`, `MealCreate`, `CustomFoodCreate`, `CustomFoodCreateWithAi`, `AdHocLogCreate`, `AiLogCreate`) use a generic route-shaped form/page shell inside the workspace when booting; no three-bar page and no page skeleton after boot.
- `Main.pageView` becomes:

```elm
pageView model =
    if not (isBootstrapped model.bootstrap) then
        Page.bootShell model.env

    else
        Element.map GotPageMsg (Page.view model.env model.route model.page)
```

`Page.view` takes `Route` from `Main`; do not store a second route in `Page.Model`.

---

## 7. Shell, Transition and Scroll Fixes

### 7.1 Split chrome suppression from page loading

Today `isLoadingPage` gates chrome for both auth boot and the date gate. Split the concepts:

- `chromeSuppressed : Model -> Bool` in `Main` means "the app is in an auth transition (boot or logout) and should show neutral wordmark chrome". Auth boot is already `Auth.Loading`, so it hides chrome without a page flag. Logout needs a new `loggingOut : Bool`.
- `Page.isLoading` remains only "waiting for today"; it is used by `Page.view` and story tests, not by chrome.

Change the signatures consistently:

- `View.Chrome.showsAppChrome : Session -> Bool -> Route -> Bool` where the `Bool` is `chromeSuppressed`.
- `View.Chrome.showBottomNav : Env -> Session -> Bool -> Route -> Bool` where the `Bool` is `chromeSuppressed`.
- `View.Chrome.topBarView` takes `chromeSuppressed`.
- `Chrome.viewFrame`, `Chrome.bottomNavLayoutAttrs` and `Main.bottomNavAttrs` take `chromeSuppressed`.
- `View.Chrome.drawerOverlay` has a **local** `isLoadingPage = False` today (`View/Chrome.elm:494-508`); remove the local and use the same `chromeSuppressed`/session/route check. It does not take an `isLoadingPage` argument today; do not claim it does.

`Main.view` computes `chromeSuppressed = model.loggingOut` and passes it down. During boot, `currentSession` is `Auth.Loading` (`Main.elm:649-657`), so `showsAppChrome` is false regardless.

Logout lifecycle:

- `Chrome.Logout` sets `loggingOut = True` (`Main.elm:292-298`).
- Clear `loggingOut` on `LogoutCompleted` (`Main.elm:163-170`), `LoginSucceeded` (`487-498`), `SetupSucceeded` (`500-512`) and `Page.SessionExpired` (`461-468`).
- `Api.Auth.logout` has no HTTP timeout (`Api/Client.elm:86`), so a hung logout would leave chrome suppressed. Add a `Process.sleep 5000` fallback message `LogoutTimedOut` that clears `loggingOut` and navigates to `AuthLogin`; a later `LogoutCompleted` is idempotent. This is a small, explicit safety net.

### 7.2 Bottom nav and reservation

The bottom nav is Phone-only (`Ui.Common.isSmall`) and 56px (`View/Chrome.elm:429-447`). Compute one predicate:

```elm
reserveBottomNav =
    UiCommon.isSmall env.device
        && Auth.isAuthenticated session
        && not (Auth.isAdmin session)
        && route /= AuthLogin
        && route /= BootstrapSetup
```

`showBottomNav` must use the same predicate plus `not chromeSuppressed`. Use it for both rendering the nav and reserving the 56px page padding; do not derive page padding from a different flag. Tablet gets no nav and the 24px gutter. Auth routes get no reservation. Admin routes get no nav/reservation. During boot the session is `Auth.Loading`, so there is no nav/reservation; the neutral boot shell changes once when the session resolves. That is the only accepted boot-time bottom change. Do not claim the reservation is stable through boot.

`Chrome.pageAttrs` takes `reserveBottomNav : Bool` and adds 56px bottom padding only when true. Do not hardcode `100dvh - 58px` in skeletons; `Ui.Workspace` already gives the pane `height fill`. If a minimum height is ever needed, subtract the nav clearance too.

### 7.3 Scroll policy

There is no scroll reset/restoration code today (no `Browser.Dom`, `scrollTo` or `scrollIntoView` in `frontend-web/src`). Route changes can leave `window.scrollY` deep; when the new skeleton is shorter, the browser clamps, and the loaded page appears mid-scroll.

**Decision:**

1. Set `history.scrollRestoration = "manual"` in `frontend-web/src/index.js` (or explicitly document an equivalent override). Browser restoration must not fight the Elm policy.
2. On `UrlChanged`, after `changeRouteTo`, determine the **rendered layout**, not the device class. If the new layout uses the single-pane branch (`Ui.Workspace.paneVisibility` yields one visible pane; i.e. pane count 1, or Phone/Tablet), reset document scroll to 0 with `Browser.Dom.setViewport 0 0`. Add a `ScrollResetCompleted`/`NoOp` message for the Task result.
3. Desktop one-pane routes (settings, lists, most edit/detail pages) use the single-pane branch and document scroll. Do **not** claim desktop is always clipped. Desktop two-pane routes use the side-by-side branch; do not touch `.ui-workspace-pane` scroll on data updates.
4. Back/forward: choose an intentional **top-reset policy**. Because restoration is manual, reset on popstate too when the new layout is single-pane; test it. If the product wants back/forward to restore position, skip the reset for popstate and add a separate restoration policy; do not leave it undefined.
5. Same-pane refresh/retry does not change the route; do not reset. Use in-place sub-skeletons for the affected region so the document height does not collapse under the current scroll.
6. Query-only changes (for example a date change) count as navigation for this policy; reset when the new layout is single-pane. Document that `lookup_note` query changes also reset.
7. Do not add a skeleton minimum height that ignores the nav; rely on `Ui.Workspace` height fill.

### 7.4 Pane key stability

Do not change `paneKey` (`Page.elm:205-284`) to encode loading state. A key change remounts the pane and destroys its DOM and scroll. Rules:

- Bootstrap skeleton panes use keys that match the eventual pane keys where computable (`food-search`, `meal-list`, `custom-food-list`, `food-detail:<id>`, `meal-detail:<id>`). They are replaced once; there is no prior pane scroll to preserve before the real pane exists.
- For undated diary panes, the key cannot match until `today` is known; use an explicit `PendingTodayKey` and accept one replacement inside the same workspace slot.
- Loaded panes keep their existing keys (`diary:<date>:<calendarMonth>`, `meal-detail:<id>`, etc.). `Page.reconcile` continues to reuse existing panes by key.
- Retry/refresh keeps the same pane key and uses in-place sub-skeletons.
- Desktop contextual panes keep the same two-key layout; the skeleton for a new right pane must not reorder the left pane.

### 7.5 Update banner

`Chrome.viewFrame` renders the update banner between the top bar and the page (`Chrome.elm:181-193`; `View/Chrome.elm:215-232`). It is a real variable-height block and shifts the page body. Do not claim page-body stability while it can appear between captures.

Decision for this initiative:

- Treat the update banner as a documented variable block, not part of the page no-jump contract.
- Add `data-testid="update-banner"`.
- Give the harness control of `/version.json`: `Fetch` can intercept it because it is not under `/api/*` (`Version.elm:100`). Fulfil it with the same `{"version": "..."}` in both loading and loaded captures so the banner is absent in both, or with the same new version in both so it is present in both. Never let it appear only between captures.
- Add one manual/nightly case with the banner already present in both states. If it must be structurally removed later, render it as an overlay or reserve its height for the session; those are separate product decisions.

### 7.6 Date-query contextual routes

`FoodSearch`/`FoodShow` with a `date` query build only their own pane while `today` is `Nothing`, then add the diary/main pane when the local date arrives (`searchWorkspaceDesired`/`foodWorkspaceDesired`, `Page.elm:1144-1180`). On desktop that is a one-time 1→2 pane addition outside the `waitingForToday` skeleton.

**Decision: do not gate the page.** A search or food detail page is usable without `today`, and the local-date port is same-tick (`frontend-web/src/index.js:19-30`), so the window is tiny. The pane-count contract starts after date resolution for these routes; the body does not jump, only the workspace gains its left pane once.

If the product later requires no pane addition:

- the preferred fix is to make the diary pane's date independent of `today` (construct it from the route date and clamp on render), not to gate a usable page; or
- add a `DateResolution = Pending | Resolved LocalDate | TimedOut` state and gate only while `Pending`, with a timeout that renders the date-query page alone. Do not ship a permanent gate that hangs when the local-context port never arrives.

If either option is adopted, `panePlanForRoute` must still own the shape; add the timeout to the shared plan/test, not to a second route `case`.

---

## 8. Per-Route Rollout Matrix

Priority:

- **P0:** visible first-paint/reflow on common routes, or blocks the shell fix.
- **P1:** common detail/settings/search/admin landing routes with a clear loaded structure.
- **P2:** lower-frequency or already-close pages.
- **None:** no async page load; no page skeleton needed.

| Pri | Route(s) | Page module | Current loading state | Recipe | Specific work | Depends on | Acceptance (fixed / anchor) |
|---|---|---|---|---|---|---|---|
| P0 | `/` boot, `/home` date gate | `Main`, `Page`, `Page/Diary/Day.elm` | 3 bars outside workspace (`Main.elm:640-646`, `Page.elm:3112-3120`) | Neutral boot shell + route skeleton | `Page.bootShell`; `Page.bootstrapView`; shared `panePlanForRoute`; chrome suppression split; nav reservation; scroll reset | Phase 1 primitives | topbar y=0/h=58; page-root/page-content x/width; pane frame after session; date card top; no pre-auth nav assertion |
| P0 | `/home`, `/home?date=...` | `Page/Diary/Day.elm` | No skeleton; real zero-data date card; slot cards appear later (`515-542`, `937-939`, `956-984`, `1113-1136`) | Diary Day | `skeletonView`; `PrefsState`; exact enabled slots; 72px empty-slot block; no fixed 5 slots; gate only pending | `elLine`, `paragraphLine`, `icon`, `dot`, `busy`; `Surface.heroCard` | date card top/left/width/height; first slot top; media 118. **Not** first log row/add button |
| P0 | `/foods/custom/:id/edit` | `Page/CustomFood/Edit.elm` | 4 inputs + button (`426-434`) | Editor, component-owned | `Component.FoodEditor.skeletonView`: basic + category block, nutrient header/hint/N rows/add footer, servings/empty/add footer, default portion responsive row/column + hint; save outside | `field`, `elLine`, `paragraphLine`, `button`, `Surface.*` | page-container/page-content; basic section top/header band; first field 64. **Not** category block, nutrient row, save |
| P0 | `/meals/:id/edit` | `Page/Meal/Edit.elm` | 4 inputs + card rows 3 + button (`506-515`) | Editor, component-owned | `Component.Meal.Form.skeletonView`: basic 2 fields, total 2 controls, components N custom rows + add footer; nutrition preview; save outside (`467-497`) | `field`, `elLine`, `paragraphLine`, `button`, `View.Nutrients` | page container; basic section top/header; first field 64; first component row top. **Not** save/nutrition |
| P0 | `/admin/users/:id/edit` | `Page/Users/EditUser.elm` | card rows 5 + button (`459-462`) | Settings/detail form | Section title + username; 2 detail rows; hairline; password field; reset button; bottom action outside (`326-406`) | section, `field`, `button`, `bottomActions` | section top/header; first detail row height; password field 64; bottom action top (fixed rows, seeded short username) |
| P1 | `/admin` | `Page/Users/Dashboard.elm` | section title + 3 rows + footer button (`138-146`) | List | Section title 24; no-leading rows; username 21 + display name 21; status badge 21; footer create button; no hairlines | `row`, `paragraphLine`, `chip`/badge, `button` | section top/header; first row top/height. **Not** footer |
| P1 | `/meals/:id` | `Page/Meal/Show.elm` | card rows 2 + section + 3 rows + 3 cards + 2 buttons (`715-731`) | Section detail | Header section (no subtitle, notes body slot); components section custom rows; nutrition formSection + preview; bottom actions (`542-616`, `661-700`) | `pageHeaderRaw`, `dot`, `field`, `bottomActions`, `View.Nutrients` | page container; header section top/header band; first component row top (seed no notes). **Not** nutrition card/bottom actions |
| P1 | `/logs/:id` | `Page/FoodLog/Entry.elm` | card rows 2 + 3 inputs + button + card rows 3 (`839-848`) | Panel detail | Panel header with 29px title + Phone two-line subtitle; optional categories; three controls; footer action; nutrition card (`563-619`) | `pageHeaderRaw`, `field`, `View.Nutrients.skeletonCard` | panel top/header band; title line. **Not** first field (category variant), footer, nutrition card |
| P1 | `/foods/:id` | `Page/Food/Show.elm` | 120px block + bars + input + button + card rows 3 (`519-528`) | Panel detail | Panel header dot + 29px title + 21px meta; optional categories; three controls; footer action; nutrition card; render route `lookup_note` synchronously (`449-494`) | `pageHeaderRaw`, `field`, `dot`, `View.Nutrients.skeletonCard` | panel top/header band. **Not** first field (category variant), footer, nutrition card |
| P1 | `/foods/custom/:id` | `Page/CustomFood/Show.elm` | 120px block + bars + card rows 3 + 2 buttons (`391-407`) | Header section + card | Header section with dot + 29px title + meta + category row; nutrition card; 2 action placeholders for user foods (`328-343`, `346-366`) | `pageHeaderRaw`, `chipRow`, `bottomActions`, `View.Nutrients.skeletonCard` | page container; header section top/header band. **Not** nutrition card/action row |
| P1 | `/details` | `Page/NutritionDetails.elm` | 40px bar + stat card + 2 cards + card (`241-256`) | Detail/settings hybrid | Date header real (or skeleton at boot); **always** banner shell; overview stats; four nutrient sections; reference; variable rows (`259-285`, `315-333`, `380-413`) | `section`, `stat`, `table`, `paragraphLine` | date header top/height; banner shell top/height (seed line count); overview top; first nutrient section top only in seeded case |
| P1 | `/search` | `Page/Food/Search.elm` | Results 3 rows; recents card rows 3; barcode card rows 2 (`1224-1231`, `1290`, `1416`) | List section / in-place | Search controls stay real; results section header 20 + 3 rows; recents/barcode are in-place skeleton regions; empty result uses `Feedback.emptyState` | `row`, `section`, `paragraphLine` | search controls top/height; results section top; first result row top; in-place region present/gone |
| P1 | `/settings/goals` | `Page/Goals/Settings.elm` | header 24 + 4 inputs + button inside (`448-461`) | Settings form | Section title 24 + description paragraph 21; 4 fields 64; save outside (`333-413`) | `section`, `field`, `button`, real static description | section top/header; first field/save top only in the seeded one-line-status case |
| P1 | `/settings/diary` | `Page/Diary/Settings.elm` | header 24 + 4 bars + button (`235-247`) | Settings form | Section title 24 + description paragraph; 5 checkbox rows 44; save outside (`171-222`) | `section`, `checkboxRow`, `button`, real static description | section top/header; first checkbox top; save top (real static description, fixed 5 rows) |
| P1 | `/settings/api-keys` | `Page/Settings/ApiKeys.elm` | button header + 3 rows (`453-462`) | List/settings | Description above section; section header button 48; 3 static rows with title 21 + 2 subtitle lines + badge/revoke; no footer (`306-338`); empty case | `section`, `row`, `paragraphLine`, `chip`, `button` | description top/height (seed locale); section top; first row top/height (seeded key) |
| P2 | `/calendar` | `Page/Diary/Calendar.elm` | Month skeleton missing weekday row, 2px gaps (`331-346`; `Ui/MonthCalendar.elm:68-80`) | Calendar | Weekday row; no inter-cell spacing; 68px-tall equal-width cells; `monthRows` shared; keep load-earlier button | `Ui.MonthCalendar` fix | month section top; weekday row top/height; first grid row top; cell height 68; width ≈ grid/7; no overflow |
| P2 | `/foods/custom` | `Page/CustomFood/List.elm` | Section header 2 buttons + 3 rows (`202-216`) | List | Keep 2 header buttons; dot leading; title 21 + 2 subtitle lines/chips; hairlines; empty paragraph | `row` | section top/header; first row top/width. **Not** footer/row count |
| P2 | `/meals` | `Page/Meal/List.elm` | Section header button + 3 rows (`182-191`) | List | Keep header create button; dot leading; title 21 + 1 subtitle line; hairlines; empty paragraph | `row` | section top/header; first row top/width |
| None | `/login` | `Page/Users/Login.elm` | Synchronous credential form (`98-100`; `Component/Users/CredentialForm.elm:122-176`) | Neutral boot shell only | No page skeleton after boot | `Page.bootShell` | No layout change after auth resolves |
| None | `/setup` | `Page/Users/BootstrapSetup.elm` | Synchronous credential form (`98-100`) | Neutral boot shell only | Same | `Page.bootShell` | Same |
| None | `/admin/users/new` | `Page/Users/CreateUser.elm` | Synchronous form (`183`) | Generic form shell at boot only | No page skeleton after boot | `panePlanForRoute` generic shell | No reflow after boot |
| None | `/settings/api-keys/new` | `Page/Settings/ApiKeyCreate.elm` | Synchronous form / created state (`46-48`, `489`) | Generic form shell at boot only | Same | `panePlanForRoute` generic shell | No reflow after boot |
| None | `/meals/new` | `Page/Meal/Create.elm` | Synchronous form | Generic form shell at boot only | Same | `panePlanForRoute` generic shell | No reflow after boot |
| None | `/foods/custom/new`, `/foods/custom/new/ai` | `Page/CustomFood/Create.elm` | Synchronous form / assistant status card (`Component/FoodAssistant.elm:648-656`) | Keep assistant card | No page skeleton | — | No page reflow after boot |
| None | `/logs/new/ad-hoc` | `Page/FoodLog/CreateAdHoc.elm` | Synchronous form | Generic form shell at boot only | Same | `panePlanForRoute` generic shell | No reflow after boot |
| None | `/logs/new/ai` | `Page/FoodLog/CreateWithAi.elm` | Assistant status card | Keep assistant card | No page skeleton | — | No page reflow after boot |
| None | `Root`, `NotFound` | `Access`, `Page` | `Root` redirects; `NotFound` placeholder | Neutral boot shell / placeholder | No route-specific skeleton | `Page.bootShell` | No wrong Diary/Login/Admin flash |

Bootstrap route bodies ship with the page phase that owns them. Until a page's phase, `panePlanForRoute` uses a generic route-shaped shell inside `Ui.Workspace`; it must never fall back to three bars and must never add a second route table. Do not add a primitive early just because a later phase will use it.

---

## 9. Partial, Asynchronous, Empty and Failure States

The rule: **gate the page if the missing data is logically required to draw the page; use an in-place sub-skeleton if the missing data only fills a slot; never use "pending" to hide a failure.**

| Page | Independent data | Recommendation |
|---|---|---|
| Diary Day | logs+goal (`diary`), prefs, latest slots | Gate on `diary = Loading` or `prefs = PrefsLoading`. Add `PrefsState = PrefsLoading | PrefsLoaded DiaryPrefs | PrefsFailed ApiError`. Prefs decide enabled slots; when loaded, render exactly the enabled slots. If prefs fail, do not skeleton forever: render the date card + warning + sections with logs. If diary fails, render the date card + error banner. Latest slots only change a button label/disabled state (`Day.elm:1026-1065`); no skeleton. |
| Custom Food Edit | food, nutrients, units | Already gates on all three (`Page/CustomFood/Edit.elm:343-356`). Keep. Do not render the editor with partial units/nutrients. |
| Meal Edit | meal, units | Gate on both. `LoadingModel` already carries `units` (`Page/Meal/Edit.elm:43-44`); do not switch to `Editing` with an empty unit list. If component names are missing, use an in-place 16px name line. |
| Food Show | food, units, optional last-used | Already gates on food+units (`Page/Food/Show.elm:336-353`). Keep. The route `lookup_note` banner is known synchronously and belongs in both skeleton and loaded. |
| Meal Show | meal, product names, nutrition preview | Gate on meal. Component names arrive independently; use a 16px `elLine` in the name slot (the loaded name is a 16px el, so no growth). Nutrition preview uses `View.Nutrients.skeletonCard` in place below the portion form. |
| Food Log Entry | log, product detail | Gate on log. Product detail title uses a 29px `paragraphLine 24` placeholder; Phone subtitle uses two 21px paragraph lines. Categories/nutrients fill in place. |
| Food Search | results, recents, barcode | Controls are synchronous and must not skeleton. Results, recents and barcode are independent in-place regions: results section header 20 + 3 rows; recents card rows 3; barcode card rows 2. Empty results use `Feedback.emptyState`. |
| Nutrition Details | report, coverage banner, expanded advice | Gate on report. The coverage banner is **always present**; reserve a banner shell (one line on Desktop, two on Phone, or render the known static message when possible). Do not exempt it. The date header is the stable first surface; the overview follows the banner. |
| Settings forms | load, save state | Gate on load. Save/validation updates in place; never re-render a page skeleton for a submit. |
| List pages | list | Gate on list; rows are variable. Keep the section header and first row top; the empty state is a single paragraph. |
| API keys | list | Gate on list. The description paragraph is part of the skeleton above the section. Seed a key for the row case; add an empty case. |

Implementation rules:

- Never replace a loaded page with a full-page skeleton for a retry. Keep the page shell and show the sub-skeleton in the affected region; this preserves scroll and avoids a document-height collapse.
- Give every in-place sub-skeleton a min-height equal to its loaded content's **fixed** part, so an async text arrival cannot move the row below it.
- If a banner is route-derived (for example Food Show's `lookup_note` query), render it in the skeleton as well, because it is known synchronously from `Route` (`Data/Route.elm:33`, `78-84`).
- If a banner is data-derived (Nutrition Details coverage), reserve its shell; do not omit it.
- Failure states are **not** universally shell-preserving today. `Goals Settings`, `Diary Settings`, `API Keys`, `Calendar` and several detail pages render only `errorRetry`/`errorBanner` on failure. Do not repeat the first draft's global claim. Either:
  - keep the section header/date card and put the error in the body for the P0/P1 pages, and list that work in the phase; or
  - document failure as exempt from the loading→loaded contract for the routes where the failed view currently replaces the body.
  This plan chooses the second as the default and adds the first only for Diary Day (date card + error) and one P1 failure case. Failure is not part of the no-jump acceptance unless a route explicitly says so.

---

## 10. Accessibility and Motion

### 10.1 Semantics

- Put `aria-busy="true"` on the **persistent page root** in `Chrome.viewFrame` while a page-level skeleton is shown, and toggle it to `"false"` when the page is loaded. `Main.view` computes `pageBusy = not (isBootstrapped model.bootstrap) || Page.isBusy model.page`; `Page.isBusy` is true for `waitingForToday` or for a pane whose page-level state is `Loading`/`NotAsked` (implement it by pattern-matching the pane models, or by a small `isLoading` helper on the page module). Do not put `aria-busy` on `Skeleton.busy`; that node is removed. In-place sub-skeletons do not toggle `aria-busy`; the page is still usable.
- Each page-level skeleton pane has one `Skeleton.busy` root with `role="status"` and one visually hidden label (`TidCommonLoading` already exists in `generated/Translations/Ids.elm:133`). Do not add `aria-live="assertive"`; loading is polite.
- In-place sub-skeletons (component name, nutrition preview, search results, retry region) are visual only: they carry `data-skeleton-region="true"` and `aria-hidden` bars, but no `role="status"` and no extra busy root. One status per page pane, not per sub-skeleton.
- Decorative bars/surfaces get `aria-hidden="true"` so a screen reader does not walk an empty tree.
- Do not add `tabindex`, `role="button"`, `onClick` or focus styles to skeleton elements. There is no fake interactivity.
- When the real page replaces the skeleton, the top bar/route title remains the h1 (`Typography.screenTitle`); no focus jump is introduced.
- Known static text rendered inside the skeleton (section titles, descriptions, button labels) is wrapped in the skeleton's `aria-hidden` subtree so the screen reader still hears only the loading status, not a duplicate page.

### 10.2 Reduced motion

The shimmer is already disabled under `prefers-reduced-motion: reduce` (`frontend-web/src/main.css:291-301`). No page should add its own keyframes. The harness runs one case with reduced motion emulated to prove the skeleton is still visible and static.

### 10.3 Visually hidden utility

There is no current `sr-only` class. Add one small global utility to `frontend-web/src/main.css`:

```css
.ui-visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
```

This is an accessibility utility, not a visual redesign.

---

## 11. Testing Plan

### 11.1 What `elm-test` can and cannot do

`elm-test` is DOM-less. It can render an Elm UI value with `Element.layout` and query visible text/ARIA with `Test.Html.Query`, but it cannot measure layout, CSS, browser events or scroll (`docs/testing.md:81-100`; `frontend-web/AGENTS.md`). The testing guide says UI tests must never assert DOM structure or CSS (`docs/testing.md:98-99`).

Therefore:

- **Pure tests:** only logic that determines the skeleton's **counts/shape**, where a wrong branch would produce a real layout bug and the logic is shared with the loaded view.
- **Browser tests:** all geometry, chrome, scroll and landmark assertions. The browser harness is a separate layout test and intentionally inspects geometry.
- **ARIA render tests:** allowed as a UI/ARIA test, with a comment explaining why it is not a property/story. Do not use them to assert layout.

Do not add tests that merely restate `bar` returns the width it was given; that violates the keep/delete bar (`docs/testing.md:34-67`). Do not duplicate existing `Ui.Workspace`/`Data.Route`/`Data.Calendar` tests.

### 11.2 Pure tests that are meaningful

Add a small number, each tied to a shared production function and a mutation that must fail:

1. **Shared pane shape.**
   `panePlanForRoute` / `panesForRoute` for date-query contextual routes with `today = Nothing`. Assert:
   - `Page.init { route = FoodShow "food-1" (Just date) (Just Lunch) Nothing, today = Nothing }` yields the immediate one-pane state (`food-detail:...`) and no `diary:` key;
   - after `adoptToday`, the same route yields two panes in main/detail order (`diary:date:none`, `food-detail:...`);
   - for every route with `today = Just date`, the plan keys equal `Page.paneKeys` after init.
   Mutation: remove the contextual main or reorder the fallback; the test fails. This is the highest-value pure test because it protects the exact 1→2 pane bug the plan is fixing. It does not restate route constructors.

2. **Calendar row partition.**
   Extract `monthRows : String -> List (List (Maybe Int))` used by both `MonthCalendar.view` and the period-known `MonthCalendar.skeleton`. Property: every month yields 4, 5 or 6 rows, every row has 7 cells, and the non-empty count equals the month's day count. Mutation check: change `monthRows` itself to `List.repeat 6` or `List.take 4`; the property fails for a 4- or 6-row month. Do not claim the test proves skeleton geometry; it proves the shared row count. Existing `Data.CalendarTest` already covers `monthCells` alignment/count; do not duplicate it.

3. **Diary visible slots.**
   Extract `visibleSlotSections : PrefsState -> List FoodLog -> List SlotSection` used by `logGroupsView`. The return type must preserve the slot identity, not just `List (Maybe MealSlot)`, and must include the unslotted `Nothing` section when unslotted logs exist. Property:
   - `PrefsLoaded` all enabled: every enabled slot appears, plus any disabled slot with logs;
   - order is `MealSlot.all` order, and the unslotted section is last;
   - no duplicates;
   - `PrefsLoading`/`PrefsFailed`: only slots with logs.
   Mutation: include an empty disabled slot, or drop the unslotted section; the test fails. Do not assert skeleton count equals this function; the skeleton uses a neutral shell when prefs are unknown.

4. **Prefs failure story.**
   A page story in `tests/Page/Diary/DayTest.elm`: logs loaded, prefs `PrefsLoaded (Err ...)` (or the equivalent failure state) → the screen is the date card + logs + warning, not a skeleton. This protects "do not hide a failure".

5. **ARIA contract (optional).**
   Render `Skeleton.busy` with `Element.layout` and query: one `[role="status"]`, the hidden label text, and no focusable descendants. Add the justification comment. If kept, note that the browser assertion also checks it; do not duplicate both without reason.

6. **Do not add** a test that maps a `Route` constructor to a skeleton constructor; that is implementation restatement. The shared pane-shape test above covers the meaningful part.

Mutation sanity: apply the documented mutations before declaring the pure tests done (`docs/testing.md:196-221`).

New test files under `tests/Data/` need a `.gitignore` negation (the root `data/` ignore is case-insensitive on macOS); see `frontend-web/AGENTS.md:95-99`. Prefer `tests/Page`/`tests/Ui` for new files to avoid the trap.

### 11.3 Browser-level layout-stability harness

**Location:** `docs/scripts/check-skeleton-stability.mjs`.

**Reuse:** factor the CDP plumbing out of `docs/scripts/capture-readme-screenshots.mjs` into `docs/scripts/lib/cdp.mjs`:

- `CdpClient` (`capture-readme-screenshots.mjs:623-687`);
- `launchChrome` (`311-375`);
- `connectToPage` (`377-387`);
- `evaluate` (`560-574`);
- `setViewport` (`427-435`);
- `waitForText` (`474-489`);
- `injectStaticStyles` (`534-549`);
- `capture` (`551-558`);
- `typeIntoInput` (`220-239`) and `clickButton` (`491-505`) for the search/failure cases;
- `trackApiRequests` (`389-425`) can stay in the screenshot script or move too.

The screenshot script runs `main()` on import, so extraction is required before a second script can import it. Prefer the extraction as a separate commit; duplicating ~120 lines is the fallback only if touching the screenshot tool is too risky.

**Auth and seed lifecycle (explicit):**

1. Read credentials from env: `CALCO_ADMIN_USER`, `CALCO_ADMIN_PASSWORD`, `CALCO_LAYOUT_USER`, `CALCO_LAYOUT_PASSWORD`. Fail fast if missing.
2. Admin login via `POST /api/auth/login`.
3. Create/reuse the layout user via `POST /api/admin/users`; this endpoint returns a session response but does **not** set a cookie (`backend/src/auth/api/http.rs:466-482`), so logging in as that user is a separate step.
4. Layout login via `POST /api/auth/login`.
5. Seed fixtures as the layout user:
   - one custom food with a known name, brand, 3 categories and a known nutrient table;
   - one meal with 2 components;
   - one breakfast log for the fixed date;
   - goal + diary prefs (all 5 slots, plus variants for 2 and 3 enabled slots);
   - one API key;
   - the layout user itself is the `/admin/users/:id/edit` target; record its id.
6. Run user cases.
7. Admin login again; run `/admin` and `/admin/users/:id/edit`.
8. Layout login again; delete fixtures in dependency order using the existing delete endpoints.
9. Admin login again; disable the layout user. There is **no user-delete route** (`backend/src/auth/api/http.rs:31-45`); do not pretend otherwise. Prefer a disposable `calco_layout` database/schema per run, which removes the need to reuse/disable a user and avoids polluting `/admin` list geometry. Never reset or truncate the developer's `calco` database.
10. Use a fresh Chrome profile per run or explicitly log out/clear cookies between admin and layout cases, so a stale session cannot change access decisions.

**Deterministic seed:**

- Fixed date: `CALCO_LAYOUT_DATE` default `2026-10-27`. The README screenshot script uses `CALCO_SCREENSHOT_DATE` (not `CALCO_LAYOUT_DATE`) with the same default (`docs/scripts/capture-readme-screenshots.mjs:22`); the new harness may add the new name. Guard that the fixed date is not in the future relative to the emulated clock, or compute a stable past date; `dateFromParam` clamps a future route date to `today` (`Page.elm:1052-1055`).
- Set `Emulation.setTimezoneOverride` to UTC and `Emulation.setLocaleOverride` to `en-US` where supported. The local date port uses `toLocaleDateString("en-CA")` (`index.js:22`); timezone override is the relevant control; the explicit locale argument is not changed by the locale override.
- Use `/home?date=${CALCO_LAYOUT_DATE}` or `/foods/...?...date=...` for deterministic screens. Do not rely on the app's real "today" for a seeded log.
- Seed variants: 2-, 3- and 5-enabled-slot Diary prefs; a food with and without categories; a meal with and without notes; API keys empty and non-empty; an empty custom-food/meal list (via `Fetch.fulfillRequest` with `[]`, or a second clean user).

**Holding loading states deterministically:**

- Use CDP `Fetch` with glob patterns against the full URL (e.g. `*/api/logs*`, not a bare `/api/*` unless verified). Enable the domain after auth, or stage the handler.
- Staged interceptor:
  1. **Before login:** continue all requests; otherwise the login `Runtime.evaluate` fetch never resolves.
  2. **Bootstrap case:** hold `*/api/auth/session` and `*/api/auth/bootstrap/status`; continue everything else (or fulfil `/version.json`).
  3. **Normal/date-gate cases:** continue auth requests; hold only the route data requests listed below.
  4. **After release:** switch to "continue everything" so newly issued requests are not accidentally held.
- `Network.setCacheDisabled { cacheDisabled: true }` before navigation; navigate fresh for each case so Elm's in-memory `Store` cache is empty. Transition cases are explicitly "warm route transition" and must not assert a skeleton where data is legitimately cached.
- Record every paused URL. Fail the case with "expected request was never paused" if a required URL is absent. This prevents a loaded-vs-loaded false green.
- Wait for the loading marker, capture; continue held requests; wait for network idle and the loaded marker; capture. Do not use a fixed sleep to define "loading"; the hold is the synchronization point.

**Exact endpoints** (from the `Api.*` modules; use these, not placeholders):

| Purpose | Method and path |
|---|---|
| Auth session | `GET /api/auth/session` |
| Bootstrap status | `GET /api/auth/bootstrap/status` |
| Login / logout | `POST /api/auth/login`, `POST /api/auth/logout` |
| Goal | `GET /api/goal?date=YYYY-MM-DD`; `PUT /api/goal` |
| Diary prefs | `GET/PUT /api/diary-preferences` |
| Logs for a date | `GET /api/logs?log_date=YYYY-MM-DD` |
| Latest slots | `GET /api/logs/latest-slots?before=YYYY-MM-DD&lookback_days=N` |
| Log summary (Calendar) | `GET /api/logs/summary?from_date=...&to_date=...` |
| Recent items | `GET /api/logs/recent-items?from_date=...&to_date=...&meal_slot=...` |
| Last-used items | `POST /api/logs/last-used` |
| Food detail | `GET /api/foods/{id}` |
| Food search | `GET /api/foods/search?...` |
| Custom foods | `GET/POST /api/foods/custom`; `PUT/DELETE /api/foods/custom/{id}` |
| Units / nutrients | `GET /api/units`, `GET /api/nutrients` |
| Meals | `GET/POST /api/meals`; `GET/PUT/DELETE /api/meals/{id}`; `GET /api/meals/{id}/nutrients?amount=...&unit=...` |
| Admin users | `GET/POST /api/admin/users`; `GET /api/admin/users/{id}`; `POST /api/admin/users/{id}/reset-password`; `POST /api/admin/users/{id}/disable`; `POST /api/admin/users/{id}/enable` |
| API keys | `GET/POST /api/auth/api-keys`; `DELETE /api/auth/api-keys/{id}` |
| Nutrition details | `GET /api/nutrition/details?date=YYYY-MM-DD` |
| Version banner | `GET /version.json?v=...` (not under `/api/*`; intercept separately) |

There is no `/api/products/{id}/units`; units are `/api/units`. There is no `/api/goals`; it is `/api/goal`. There is no `/api/diary-prefs`; it is `/api/diary-preferences`. There is no `/api/latest-slots`; it is `/api/logs/latest-slots`. There is no `/api/diary/summaries`; it is `/api/logs/summary`.

**Deterministic date-gate seam:**

The local date is sent from a same-tick port (`index.js:26-30`), so a network hold cannot catch the `waitingForToday` window. Add a dev-only seam:

```js
// frontend-web/src/index.js, development only
const holdLocalCtx =
  import.meta.env.DEV && new URLSearchParams(location.search).has("holdLocalCtx");
if (holdLocalCtx) {
  window.__calcoSendLocalCtx = sendLocalCtx;
} else {
  sendLocalCtx();
}
```

The harness navigates to `/home?date=...&holdLocalCtx=1`, captures the date-gate skeleton, then calls `window.__calcoSendLocalCtx()` to release. The flag is ignored in production builds. If the team rejects this seam, remove the date-gate case from the automated blocking matrix and mark it manual QA; do not pretend `NavigationTest` proves the shell.

**Split the boot cases:**

| Case | What it proves | Required assertions |
|---|---|---|
| `bootstrap-auth` | Pre-session neutral shell | topbar 58, page-root/page-content, workspace pane, skeleton region; **no bottom nav assertion**; no route-specific body promise |
| `diary-date-gate` | Authenticated date gate | login first; hold logs/goal/latest; date seam; topbar, nav, page frame, date card, first slot, media 118; release date/data; loaded state; no add-button/log-row assertion |
| `admin-boot` | Admin first paint | admin session, `/` or `/admin`; admin dashboard section/first row; neutral root does not flash a diary body |

Do not name a single case `bootstrap-diary` and then assert a nav while auth is held.

**Markup and test ids:**

Add `data-testid` through `Element.htmlAttribute`; attributes do not change layout. Place ids on the shared geometry roots so both loading and loaded paths get them:

| Test id | Where |
|---|---|
| `app-topbar` | `View.Chrome.topBarView` root row |
| `app-bottom-nav` | `View.Chrome.bottomNavContainer` root row |
| `page-root` | `Chrome.viewFrame` page wrapper (the `<main>` element) |
| `page-content` | `Ui.Workspace.view` content root |
| `workspace-pane` | `Ui.Workspace` pane wrapper, with `data-pane="main"` or `"detail"` |
| `page-container` | `Ui.Page.pageContainer` root column (optional; not all pages use it) |
| `page-header` | new `Ui.Page.pageHeaderRaw` root |
| `surface` | `Ui.Surface.surfaceShell` root (applies to card/panel/section/heroCard) |
| `surface-header` | `Ui.Surface.panel` header band and `heroCard` media header |
| `list-row` | `Ui.Surface.listRow`/`staticRow` root and `Skeleton.row` |
| `diary-date-card` | Diary date card, loaded and skeleton |
| `meal-slot-card` | Diary slot card, loaded and skeleton (repeated) |
| `component-row` | Meal Show component rows, loaded and skeleton |
| `stat` | Nutrition Details overview item and skeleton stat |
| `search-controls` | Food Search controls root, loaded and skeleton |
| `action-primary` | primary save/submit button on the pages that claim it |
| `empty-state` | `Feedback.emptyState` / `emptyStateWithIcon` |
| `error-banner` | `Feedback.errorBanner` / `errorRetry` |
| `nutrition-card` | `View.Nutrients.nutritionCard` and `skeletonCard` |
| `calendar-weekdays` | `Ui.MonthCalendar` weekday row, loaded and skeleton |
| `calendar-grid` | `Ui.MonthCalendar` grid column, loaded and skeleton |
| `update-banner` | `View.Chrome.updateBanner` root |
| `coverage-banner` | Nutrition Details coverage notice, loaded and skeleton |

Markers:

- Every skeleton region, page-level or in-place, gets `data-skeleton-region="true"` on its root.
- Page-level `Skeleton.busy` roots additionally get `data-skeleton-page="true"`; in-place sub-skeletons do not.
- The page root gets `data-page-loaded="true"` when loaded; page-local loading roots get `data-page-state="loading"`. Do not rely on English marker text (`"CALORIES"`, `"Portion"`, `"Chicken"`) for the loaded transition.
- `data-pane="main"|"detail"` lets the harness scope repeated `surface`/`list-row`/`page-header` queries to a pane. `Page` supplies the role to `Ui.Workspace` (or to a wrapper inside the pane), so a single visible contextual detail pane on Phone is marked `detail`, not inferred from pane order. Do not compare a flat document-order array on a two-pane route.
- `Ui.Surface.surfaceShell` is the common root for card/panel/heroCard. Adding `surface` there deliberately tags skeleton cards too; if a case's `surface-0` is not the intended panel, use `surface-header` or a role-specific id instead.

**Capture function:** pseudocode run after two `requestAnimationFrame` callbacks, with fonts ready and animations disabled:

```js
(() => {
  const box = (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  };
  const paneEls = [...document.querySelectorAll('[data-testid="workspace-pane"]')]
    .filter((el) => getComputedStyle(el).display !== "none");
  const within = (pane, id) =>
    [...pane.querySelectorAll(`[data-testid="${id}"]`)].map(box);
  return {
    viewport: { width: innerWidth, height: innerHeight },
    scrollY: window.scrollY,
    docHeight: document.documentElement.scrollHeight,
    topbar: box(document.querySelector('[data-testid="app-topbar"]')),
    bottomNav: document.querySelector('[data-testid="app-bottom-nav"]')
      ? box(document.querySelector('[data-testid="app-bottom-nav"]'))
      : null,
    pageRoot: box(document.querySelector('[data-testid="page-root"]')),
    pageContainer: document.querySelector('[data-testid="page-container"]')
      ? box(document.querySelector('[data-testid="page-container"]'))
      : null,
    panes: paneEls.map((pane) => ({
      role: pane.getAttribute("data-pane"),
      box: box(pane),
      pageContent: within(pane, "page-content"),
      pageHeader: within(pane, "page-header"),
      surfaces: within(pane, "surface"),
      surfaceHeaders: within(pane, "surface-header"),
      rows: within(pane, "list-row"),
      componentRows: within(pane, "component-row"),
      stats: within(pane, "stat"),
      nutritionCards: within(pane, "nutrition-card"),
      dateCards: within(pane, "diary-date-card"),
      slotCards: within(pane, "meal-slot-card"),
      calendars: within(pane, "calendar-grid"),
      weekdayRows: within(pane, "calendar-weekdays"),
      emptyStates: within(pane, "empty-state"),
      errorBanners: within(pane, "error-banner"),
    })),
    skeletonRegions: document.querySelectorAll('[data-skeleton-region]').length,
    pageSkeletons: document.querySelectorAll('[data-skeleton-page]').length,
    focusableInSkeleton: document.querySelectorAll(
      '[data-skeleton-region] button, [data-skeleton-region] a, ' +
        '[data-skeleton-region] input, [data-skeleton-region] [tabindex]'
    ).length,
    pageLoaded: document.querySelector('[data-page-loaded="true"]') !== null,
    updateBanner: document.querySelector('[data-testid="update-banner"]') !== null,
  };
})()
```

**Assertions (exact contract):**

1. **Loading present:** `skeletonRegions > 0`; for page-level cases `pageSkeletons >= 1` (one per pane); for in-place-only cases `pageSkeletons === 0` but `skeletonRegions > 0`.
2. **Loaded:** `skeletonRegions === 0`, `pageLoaded === true`, and the route-specific loaded anchor exists (e.g. `dateCards[0]`, `componentRows[0]`, `rows[0]`, `emptyStates[0]`).
3. **Fixed envelope:** for each declared landmark, `|Δx| <= 1`, `|Δy| <= 1`, `|Δwidth| <= 1`, `|Δheight| <= 1`. Compare declared selectors by pane and index, not the whole repeated array.
4. **First anchor:** for each declared anchor, `|Δx| <= 1`, `|Δy| <= 1`, `|Δwidth| <= 1`; height is not compared.
5. **Header bands:** `surface-header` top and height equal for the first fixed surface. `surface-0` top/left/width equal; height only for fixed-seed surfaces.
6. **Chrome:** `topbar.y === 0`, `topbar.height === 58`; `bottomNav.height === 56` and `bottomNav.y + bottomNav.height === viewport.height` for authenticated Phone non-admin non-auth routes; nav absent for Tablet, admin, auth, and pre-session. On iOS manual QA, allow `topbar.y === safe-area-inset-top`.
7. **Pane stability:** visible pane count equal after session/date resolution; each pane role and x/width equal; `data-pane` scoping used. Desktop two-pane routes have `main` + `detail`.
8. **No scroll clamp:** start a single-pane route at `scrollY = 400` (not 0), navigate to a short page, assert the documented reset policy (0 after reset) and no intermediate non-zero jump; for an in-place retry at 400, assert `scrollY` unchanged (±1) and the visible anchor's `getBoundingClientRect().top` unchanged. Do not use `scrollY = 0` as the only scroll test.
9. **Back/forward:** trigger history back/forward, assert the same topbar/nav boxes and the documented scroll policy (top reset). Note the launch flags disable BackForwardCache, so this is not a bfcache test.
10. **No focusable skeleton:** `focusableInSkeleton === 0`.
11. **ARIA:** the page root has `aria-busy="true"` while loading and `"false"` when loaded; one `role="status"` per page pane; the hidden label is present; in-place regions have no status role.
12. **Calendar geometry:** weekday row present; first cell height 68 ±1; cell width ≈ `grid.clientWidth / 7` ±1 (or loading width equals loaded width); `grid.scrollWidth <= grid.clientWidth + 1`.
13. **No 120px placeholder:** Food Show/Custom Food Show first `surface-header` exists and its height equals the loaded header band; a 120px block is not the first surface.
14. **Update banner:** `updateBanner` presence is identical in both captures; `/version.json` was fulfilled with the same version in both. A change between captures is a failure, not a tolerance.
15. **Narrow phone:** `document.documentElement.scrollWidth <= clientWidth + 1`; page container x/width unchanged; action remains reachable.

**Viewport matrix:**

| Case | Width x height | Device class | Notes |
|---|---:|---|---|
| Phone | 390 x 844 | Phone | `isSmall` true; bottom nav only if authenticated non-admin; 16px gutter |
| Tablet | 768 x 1024 | Tablet | **No bottom nav**; 24px gutter |
| Desktop | 1440 x 900 | Desktop | One-pane routes document-scroll; two-pane routes clipped panes |
| Big desktop | 1600 x 1000 | **Desktop** | Not BigDesktop; BigDesktop starts >1920 (`Main.elm:252-267`) |
| Narrow phone | 360 x 800, 320 x 568 | Phone | Overflow/chip/action check |
| QA phone | 375 x 667 | Phone | Manual QA runbook preset; harness may add as nightly |
| Phone reduced motion | 390 x 844 | Phone | Geometry same; shimmer disabled |
| Dark mode | 390 x 844 | Phone | Geometry only; nightly |

The blocking matrix uses light mode, Phone + Desktop; Tablet is blocking for shell/P0, but it must assert **no nav**, not a nav. 1600 is optional/nightly and is Desktop.

**Route matrix for the harness:**

| Case | Route | Held requests / trigger | Required assertions | Deliberately not asserted |
|---|---|---|---|---|
| `bootstrap-auth` | `/home` first load | `*/api/auth/session`, `*/api/auth/bootstrap/status` | topbar, page-root/page-content, workspace pane, skeleton region; no nav | nav, page body content |
| `diary-date-gate` | `/home?date=CALCO_LAYOUT_DATE&holdLocalCtx=1` | after login; hold `*/api/logs?log_date=*`, `*/api/goal?date=*`, `*/api/logs/latest-slots?*`; release date via `window.__calcoSendLocalCtx()`, then allow `/api/diary-preferences` through | topbar, nav, workspace, date card top/left/width/height, first slot top, media 118 | first log row, add button, slot count before prefs |
| `diary` | `/home?date=CALCO_LAYOUT_DATE` | `*/api/logs?log_date=*`, `*/api/goal?date=*`, `*/api/logs/latest-slots?*`; allow prefs | date card, first slot top, 118 media; prefs-hydrated exact 2/3/5 count variant | first log row, add button, later slot tops |
| `calendar` | `/calendar` | `*/api/logs/summary?*` | month section top, weekday row top/height, first grid row top, cell height 68, width ≈ grid/7, no overflow | month/row count, load-earlier |
| `custom-food-edit` | `/foods/custom/:id/edit` | `*/api/foods/{id}`, `*/api/nutrients`, `*/api/units` | page container, basic section top/header band, first field 64 | category block, nutrient row, save, later sections |
| `meal-edit` | `/meals/:id/edit` | `*/api/meals/{id}`, `*/api/units` | page container, basic section top/header, first field 64, first component row top | save, nutrition preview |
| `admin-edit` | `/admin/users/:id/edit` | `*/api/admin/users/{id}` | section top/header, first detail row, password field 64, bottom action top (seeded short username) | multi-line username, error banner variant |
| `admin-list` | `/admin` | `*/api/admin/users` | section top/header, first row top/height | footer, user count |
| `meal-show` | `/meals/:id` | `*/api/meals/{id}`, `*/api/meals/{id}/nutrients?*`, `*/api/foods/{id}` | header section top/header band, first component row top | nutrition card, bottom actions, notes variant |
| `food-log` | `/logs/:id` | `*/api/logs/{id}`, `*/api/units`, `*/api/foods/{id}` | panel top/header band, title line | first field (category variant), footer, nutrition card |
| `food-show` | `/foods/:id?date=...&meal_slot=...` | `*/api/foods/{id}`, `*/api/units`, `*/api/logs/last-used` | panel top/header band, title line; seeded no-category first control variant | nutrition card, category variant, footer |
| `custom-food-show` | `/foods/custom/:id` | `*/api/foods/{id}` | page container, header section top/header band | nutrition card, action row |
| `nutrition-details` | `/details?date=CALCO_LAYOUT_DATE` | `*/api/nutrition/details?date=*` | date header top/height, coverage banner top/height, overview top, first nutrient section top in seeded case | later sections, long message variant |
| `search` | `/search?date=...` plus a typed seeded query | `*/api/logs/recent-items?*`, `*/api/foods/search?*`; type query | search controls top/height, results section top, first result row top; in-place region present/gone | ad-hoc section, total height |
| `goals` | `/settings/goals` | `*/api/goal?date=*` | section top/header; first field/save top only in seeded one-line-status case | validation/multi-line status variant |
| `diary-settings` | `/settings/diary` | `*/api/diary-preferences` | section top/header, first checkbox top, save top (static description, fixed 5 rows) | description wrap variants |
| `api-keys` | `/settings/api-keys` | `*/api/auth/api-keys` | description top/height, section top, first row top/height (seeded key) | row count |
| `api-keys-empty` | `/settings/api-keys` | fulfil `[]` | description top, section top, empty-state present; no first row | row height |
| `lists-empty` | `/foods/custom` or `/meals` | fulfil `[]` | section top/header, empty-state present; no first row | row height |
| `failure-retry` | `/home?date=...` or a P0 edit | fulfil one request with 500, then click Retry | shell/date card/section top unchanged, `error-banner` present, retry loading region, post-retry anchor unchanged | content inside error text |
| `two-pane-scroll` | `/foods/:id?date=...` at 1440 | hold detail; load both panes; scroll the main pane to 300; retry/update the detail | two panes with `data-pane` main/detail; pane x/width stable; main pane `scrollTop` preserved; document `scrollY` 0 | detail content height |
| `transition-scroll` | long page → short page; in-place retry at 400 | route change; Retry | single-pane reset policy (0) with no intermediate non-zero; in-place `scrollY` unchanged; pane `scrollTop` preserved on desktop | document height as proof |
| `narrow-overflow` | 360x800, 320x568 on loaded pages | — | no horizontal overflow; page container x/width stable | full landmark matrix |
| `update-banner` | any P0 route | fulfil `/version.json` with a new version in both captures | `update-banner` present/absent identically; page body shift documented | page top stability while banner is variable |

Runtime budget: PR subset (6-8 cases × Phone + Desktop) should stay ≤5 minutes; the full matrix is nightly/manual (~15-30 minutes with seeding and login). Do not run 17×3 cases as a PR gate.

**Artifacts on failure:**

- Write `loading.png` and `loaded.png` with `Page.captureScreenshot`.
- Write `result.json` with viewport, case name, pane boxes, landmark boxes, deltas, scroll before/after, paused URL set, and the list of violated assertions.
- Directory: `docs/images/skeleton-stability/<timestamp>/<case>/`; add `docs/images/skeleton-stability/` to `.gitignore`. Artifacts are local/CI uploads, not committed.

**Flakiness controls:**

- Fixed viewport via `Emulation.setDeviceMetricsOverride`, device scale factor 1.
- Headless Chrome flags already used by the screenshot script (`--force-device-scale-factor=1`, `--hide-scrollbars`, `--disable-features=...`, `capture-readme-screenshots.mjs:311-340`). `--hide-scrollbars` hides scrollbar-width differences; run a second desktop case without it for the scrollbar/nav shift check.
- `await document.fonts.ready` before capture.
- Inject ` *, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }`.
- Navigate fresh/reload for each first-load case so the Elm `Store` cache is empty; label transition cases "warm" and do not assert a skeleton there.
- Fresh Chrome profile or explicit logout/clear cookies between admin and user cases.
- Pin `/version.json` as above; do not let the update banner appear between captures.
- Scroll to the documented position and set `scrollBehavior = "auto"` before capture; for the deep-scroll test set `window.scrollTo(0, 400)` explicitly.
- Wait two `requestAnimationFrame` callbacks plus a short settle after the marker; no arbitrary long sleeps.
- Compare raw rectangles; 1px tolerance covers subpixel/font rounding.
- Run cases serially against one dev server/database; never parallelize.
- One retry on a `waitForIdle` timeout; fail with artifacts otherwise.

### 11.4 What the browser harness cannot test

- **Font rendering across OS/browser:** Inter may be unavailable and fall back to system sans. Text wrapping can differ. Use the seed and tolerance; do not assert pixel-identical screenshots.
- **Real network timing/jitter:** the harness holds requests deliberately; it does not reproduce slow 3G. Manual QA covers that.
- **Perceived shimmer quality/motion:** it disables animation for capture. The reduced-motion case only proves static visibility.
- **Screen reader announcement order/timing:** it checks ARIA attributes, not assistive-technology output.
- **iOS Safari `dvh`, safe-area insets and rubber-band scrolling:** Chrome emulation is not Safari. `100dvh` and `env(safe-area-inset-*)` need manual device checks.
- **User data outside the seed:** different row counts, long names, missing categories and conditional banners are variable content by design.
- **Browser zoom/text scaling:** separate manual check at 200% zoom.
- **CSS cascade outside Elm:** the harness checks computed geometry, which is the right layer, but it cannot prove every theme/token combination.
- **BackForwardCache:** the launch flags disable it (`capture-readme-screenshots.mjs:333`); a back/forward test is a history/scroll test, not a bfcache test.
- **Native select/dropdown popups:** they are browser UI, not DOM geometry.

### 11.5 CI and local integration

The repo currently has **no CI configuration** (no `.github/` workflow or other CI file in `git ls-files`). Do not describe a blocking CI gate that does not exist.

Add a `just` target:

```make
check-skeleton-layout:
    node docs/scripts/check-skeleton-stability.mjs
```

It requires the dev server, PostgreSQL seed data and Chrome. It is **not** part of `just check-frontend` (`justfile:144`), which must remain runnable without a browser or DB. Keep `just screenshots` (`justfile:102-103`) unchanged.

Policy:

- **Phase 0-2:** report-only, non-blocking. Run locally and nightly/manual.
- **If a CI job is added:** a small P0 subset for PRs (6-8 cases × Phone + Desktop) and a nightly/full job for the rest. Always set `CALCO_REQUIRE_LAYOUT=1` in a required job; never silently exit 0 when Chrome is missing. Only local runs may skip, with an explicit "skipped" message.
- **Promotion rule:** at least **20 consecutive green runs over at least 14 days with zero flakes**, tracked in the job summary. Replace "two consecutive weeks" with this measurable rule.
- Install Chrome/Chromium and set `CALCO_URL`/`CHROME`; upload `result.json` and screenshots; never commit artifacts.

### 11.6 Manual QA fallback

Add a section to `docs/qa-runbook.md`:

1. Start the app with the standard QA environment (`docs/qa-runbook.md:29-38`).
2. In Chrome DevTools, set Network to "Slow 3G" and disable cache.
3. Hard-reload `/home`, `/foods/custom/:id/edit`, `/meals/:id/edit`, `/meals/:id`, `/foods/:id`, `/settings/api-keys`, `/calendar` at 375x667, 768x1024 and 1440x900.
4. Record the y position of the top bar, date card/first section and first row before and after load using the inspector.
5. Use the dev-only date seam (`?holdLocalCtx=1`) when available; otherwise set a breakpoint in `sendLocalCtx` and step through the date gate. If neither is possible, record the date-gate shell as a manual check and do not claim automated coverage.
6. Toggle OS "Reduce motion"; confirm the skeleton is static and still visible.
7. Scroll to 400 on a long page, navigate to a short page and back; confirm the top-reset policy and no clamped mid-page landing. On desktop, also test a two-pane route and confirm pane scroll is preserved.
8. On iOS Safari, verify bottom-nav clearance and `dvh` with browser chrome visible/hidden; verify safe-area top.
9. Check 360/320px overflow and 200% zoom.
10. If the harness is unavailable, attach before/after screenshots to the QA record.

---

## 12. Implementation Phases

Sizes are rough engineer-days for one engineer familiar with the codebase, including tests and review. They are not calendar promises; add review/QA time.

| Phase | Work | Size | Risk | Exit criteria |
|---|---|---:|---|---|
| 0. Test seams + baseline | Add `data-testid`/skeleton markers to shared roots; extract CDP lib (separate commit); write the harness route matrix against current code; add auth/seed/date seam; capture baseline failures for P0/P1 | 3-5 d | Low | Harness runs locally; baseline JSON/screenshots stored; no production visual change; paused-URL preflight works |
| 1. Shell + pane plan + Diary | `elLine`, `paragraphLine`, `icon`, `dot`, `busy`; `panePlanForRoute` + `bootstrapView` + `bootShell`; chrome suppression split; nav reservation; scroll policy; `PrefsState`; Diary date card/slots; remove `Skeleton.loading` | 5-7 d | Medium-High | Boot/date-gate/diary cases pass topbar/nav/workspace/date-card/first-slot assertions; chrome no longer hides on date gate; Diary no longer shows zero goals/zero totals; no second route table |
| 2. P0 edit pages | Custom Food Edit; Meal Edit; Admin Edit User; `Component.FoodEditor.skeletonView`; `Component.Meal.Form.skeletonView`; `field`; `bottomActions` | 3-4 d | Medium | P0 route cases green at Phone/Tablet/Desktop; first field 64; section/header and first row anchors stable; save-top below variable rows not asserted |
| 3. P1 detail/settings/search/admin | Admin Dashboard, Meal Show, Food Show, Food Log Entry, Custom Food Show, Nutrition Details, Food Search, Goals, Diary Settings, API Keys; add `pageHeaderRaw`, `row`, `chipRow`, `stat`, `table`, `checkboxRow`, `bottomActions`, `View.Nutrients.skeletonCard` | 6-9 d | Medium | P1 matrix green; coverage banner reserved; Meal Show section structure correct; three portion controls; empty/failure variants for the chosen P1 pages |
| 4. P2 calendar/lists | `MonthCalendar` weekday row/spacing/`monthRows`; Calendar; Custom Food List; Meal List | 2-3 d | Low | Calendar cell height 68 / width ≈ grid/7 / no overflow; list first-row anchors stable |
| 5. Hardening | Remove dead exports/old primitives; tune tolerances; docs (`frontend.md`, `testing.md`, `qa-runbook.md`); promote harness per policy | 2-3 d | Low | `just check-frontend` green; harness policy documented; 20-run/14-day record before blocking |

Total: roughly **24-31 engineer-days**, or **6-8 calendar weeks** for one engineer including review, QA and the unavoidable integration work. The first draft's 11-18 days was optimistic.

### 12.1 Smaller MVP path

Ship most of the value without betting on the full matrix:

1. **Phase 0 (3 days):** test seams + harness for only `/home?date=...`, `/foods/custom/:id/edit`, `/foods/:id`, `/settings/goals`, plus `bootstrap-auth` and `diary-date-gate`. Report-only.
2. **Phase 1 (4-5 days):** chrome split, `loggingOut`, nav reservation, `bootShell`, `bootstrapView` for Diary and the date gate, shared `panePlanForRoute` (generic skeletons for unmigrated routes), `PrefsState`, Diary date card/slots, scroll reset, remove `Skeleton.loading`. Do not change `listRow`/`input` globally.
3. **Phase 2 (3-4 days):** P0 edit pages with component-owned skeletons.
4. **Defer:** full P1/P2 recipes, the complete primitive table, failure-shell changes, date-query gate, back/forward restoration, update-banner overlay, zero-goal date-card reservation, and the full 17-route matrix.

The MVP still fixes the two largest jumps and proves the pane plan, the primitive line model and the harness before the broader rollout.

### 12.2 Deferred explicitly

- `Skeleton`'s old `input` 48px and `listRow` signatures are not changed in Phase 1; migrate per page. Remove them only after the last call site.
- A date-query pane gate and any `DateResolution` timeout are deferred; the documented policy is one-time pane addition.
- Failure views for pages that currently replace the body are not rewritten globally; only Diary plus one P1 failure case are in scope initially.
- The update banner remains a variable block; overlay/reservation is a separate product decision.
- Zero-goal Diary date-card height, notes variants on Meal Show, category variants on Food Show/Entry, and stat line-count variants are documented as variable; exact-seed variants can be added later.
- Route-aware document title and artificial skeleton delay remain out of scope.

### 12.3 Quality gates for every phase

```bash
just check-frontend-line-length
just check-frontend-review
just test-frontend
just format-frontend
just build-frontend
just check-frontend
just check-skeleton-layout   # after Phase 0; browser/DB required
```

`just check-frontend` runs format-check, line length, review, build and tests (`justfile:144`); run it before each merge. The layout harness is separate.

---

## 13. Risks, Open Questions, Alternatives, Acceptance

### 13.1 Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| `panePlanForRoute` refactor changes key/order behavior | Pane jumps or lost scroll | One plan shared by `panesForRoute` and `bootstrapView`; shared-shape test; existing `NavigationTest` stories; migrate in Phase 1 before page recipes |
| `NoUnused.Exports` on staged primitives | Blocks merge | Land each with a real consumer; test usage is acceptable under the default rule; keep the primitive table as a checklist |
| `NoUnused.CustomTypeConstructors`/`Args` on internal ADTs | Blocks merge | Use every constructor/argument in production and tests; `PrefsState` and `PaneKey` are justified |
| `NoMissingTypeAnnotationInLetIn` / 100-column limit | Friction in large recipes | Extract annotated page-local helpers; split signatures; run formatter/lint early |
| Line model still wrong for a font/fallback | Row drift | Calibrate 13/16/20/24/32/44 in the harness; render known static text; keep `elLine`/`paragraphLine` in one place |
| Variable rows above save/nutrition | False promise or seed-fragile tests | Envelope + anchor contract; never assert save/nutrition top below variable rows; use exact-seed markers only |
| Diary prefs failure hidden | Permanent skeleton | `PrefsState`; gate only pending; failure warning/log body; page story |
| Date-gate seam rejected | Automated coverage gap | Demote date gate to manual; do not claim `NavigationTest` proves the shell |
| Harness holds wrong URL | False green/timeout | Endpoint table; paused-URL preflight; fail if expected request not paused |
| In-place skeleton invisible to harness | Tests skip the loading state | `data-skeleton-region` on every region; `data-skeleton-page` only page-level; count both |
| `--hide-scrollbars` hides nav/scrollbar shift | Missed horizontal jump | Second desktop case without the flag; compare `clientWidth` and page x |
| Update banner appears between captures | False body shift | Intercept `/version.json`; same banner state both captures; document variable |
| Root/auth ambiguity | Wrong first body | Neutral boot shell; no Diary/Admin/Login guess; admin-boot case |
| Chrome suppression split changes logout | Flash or stuck chrome | `loggingOut`; clear on all auth completions; 5s fallback; test logout success/failure |
| Bottom-nav over-reservation | Blank tablet/auth/admin space | Phone-only predicate; exclude auth/admin; test 390/768/1440 |
| Scroll reset surprises | Perceived jump on desktop | Reset only the rendered single-pane layout; document top-reset policy; test deep scroll and back/forward |
| Fixed seed hides real data | Harness passes while real pages jump | Seed long names/categories/multiple rows; add 2/3/5 slots, empty, failure; mark variable content |
| No user-delete route | Polluted admin list/permanent users | Disposable DB/schema; reusable layout user; disable and log; never reset the dev DB |
| CDP harness flaky | False negatives | Fixed viewport, fonts ready, animations off, fresh cache/profile, one retry, artifacts, report-only first |
| `data-testid` double-tagging | Wrong `surface-0` | Shared roots + `data-pane` scoping + role-specific ids; verify each route's surface-0 |

### 13.2 Open questions

1. **Date-query contextual routes:** keep the documented one-time pane addition, or make the diary pane date-independent / add a timeout-guarded gate? The plan chooses the first; revisit only with product direction.
2. **Zero-goal Diary date card:** should the loaded page always reserve the pill/"of kcal" space, or is the zero-goal height variable? A product decision; the skeleton assumes a non-zero seed.
3. **Failure layout:** keep the section/date card on failure for P0/P1 pages, or continue to exempt failed views? The plan does the former for Diary and one P1 case, and documents the rest as exempt.
4. **Tablet nav:** keep Phone-only (current `isSmall`), or introduce a tablet nav? If changed, the reservation and harness matrix change first.
5. **Update banner:** variable block (this plan), overlay, or reserved height? Overlay/reservation is a separate product change.
6. **Skeleton delay:** show after 100-150ms to avoid flicker on fast responses? A timer/state change; not in this pass.
7. **Route-aware document title:** low risk, orthogonal to layout; deferred.
8. **HAR vs live DB in CI:** a HAR avoids DB setup but drifts from the API; start with disposable DB + API seed.
9. **`stat` third line:** always reserve it (this plan) or change `overviewItem` to always render an empty third line for exact complete-coverage height? A small UI decision.
10. **`Page.isLoading` test helper:** keep it for the story (test usage is accepted) or expose `Page.isAwaitingToday` and assert `paneKeys == []`; either is fine as long as the story does not read the opaque `Page.Model`.

### 13.3 Alternatives considered

- **Keep the current 3-bar skeleton and only fix chrome.** Rejected: the page body still snaps from three bars to a padded column. Chrome alone is not the main jump.
- **One generic page skeleton for every route.** Rejected: list, detail, settings and diary pages have different first-block geometry.
- **Put all recipes in `Ui.Skeleton.*` modules.** Rejected: recipes need route/page data, would violate the `Ui` dependency direction, and would create speculative modules before adoption.
- **Keep `Page.Skeleton` as a second dispatcher.** Rejected: it either duplicates `panesForRoute` or requires importing `Page` (cycle). One route plan in `Page.elm` is simpler.
- **Use Playwright/Puppeteer.** Rejected for now: the repo already has a working CDP client and no browser-automation dependency. Adding a heavy dependency is not justified for one harness.
- **Screenshot pixel diff instead of landmark boxes.** Rejected: screenshots are sensitive to fonts, subpixel rendering and antialiasing. Landmark boxes encode the contract and produce actionable deltas.
- **Artificial skeleton minimum duration.** Rejected initially: it makes fast loads slower and adds timers.
- **Keep the old page while loading (SWR).** Rejected for this pass: bigger state change, stale-data risks, and the page ADTs assume a fresh load.
- **Gate date-query pages permanently.** Rejected: it turns a usable search/detail page into a gated page and can hang if the local-date port never arrives.

### 13.4 Acceptance criteria for the whole initiative

1. No call site renders a full page as three bars. `Skeleton.loading` is deleted from the module.
2. Bootstrap and date-gated routes render a route-shaped skeleton inside `Ui.Workspace`; the top bar stays 58px and the route title stays visible.
3. There is exactly one route plan; `panesForRoute` and `bootstrapView` consume it. A shared-shape test exists.
4. Page skeleton functions are public, polymorphic `Element msg`; the page's own loading branch and the boot dispatcher call the same function.
5. On authenticated Phone app routes that are non-admin and not login/setup, the bottom-nav space is 56px in loading and loaded states; the nav does not appear/disappear during ordinary fetches. Tablet, admin and auth routes have no nav.
6. P0 and P1 routes pass the browser harness at 390x844, 768x1024 (shell/P0, no nav) and 1440x900 with the fixed envelope and anchors ≤1px, no focusable skeleton nodes, and the documented scroll behaviour.
7. Calendar has a weekday row, 68px-tall equal-width cells, and no horizontal overflow.
8. Diary Day shows a date-card skeleton and the neutral/exact prefs-driven slot shells instead of zero goals/zero totals; prefs failure shows an error/warning, not a permanent skeleton; the date card and first slot do not move.
9. Nutrition Details always reserves the coverage banner; Meal Show uses its section structure; Food Show/Food Log Entry use three portion controls; no page starts with a 120px block that does not exist in the loaded state.
10. Reduced motion leaves a static, visible skeleton; ARIA exposes one status per page pane; the page root toggles `aria-busy`; no fake controls.
11. `just check-frontend` passes; the layout harness is documented with a report-only/nightly policy and a measurable promotion rule; no required job silently skips Chrome.
12. No new runtime dependency and no visual-language redesign.

---

## 14. Appendix

### 14.1 Route / page inventory

| Route | Page module | Current loading UI | Target recipe | Priority |
|---|---|---|---|---|
| `/` (`Root`) | `Access` → `AdminDashboard`/`AuthLogin`/`DiaryDay` | Redirect; pre-session 3 bars | Neutral boot shell, then route skeleton | P0 |
| `/login` | `Page/Users/Login.elm` | Synchronous `CredentialForm` (`98-100`) | Boot shell only; no page skeleton | None |
| `/setup` | `Page/Users/BootstrapSetup.elm` | Synchronous `CredentialForm` (`98-100`) | Boot shell only | None |
| `/home` | `Page/Diary/Day.elm` | No skeleton; zero-data date card; slots appear later (`515-542`, `937-939`, `956-984`, `1113-1136`) | Diary Day | P0 |
| `/calendar` | `Page/Diary/Calendar.elm` | Month skeleton missing weekday row, 2px gaps (`331-346`; `Ui/MonthCalendar.elm:68-80`) | Calendar | P2 |
| `/details` | `Page/NutritionDetails.elm` | 40 bar + stat card + 2 cards + card (`241-256`) | Nutrition sections; banner reserved | P1 |
| `/settings/goals` | `Page/Goals/Settings.elm` | Header 24 + 4 inputs + button inside (`448-461`) | Settings form | P1 |
| `/settings/diary` | `Page/Diary/Settings.elm` | Header 24 + 4 bars + button (`235-247`) | Settings form | P1 |
| `/settings/api-keys` | `Page/Settings/ApiKeys.elm` | Button header + 3 rows (`453-462`) | List/settings | P1 |
| `/settings/api-keys/new` | `Page/Settings/ApiKeyCreate.elm` | No page fetch (`46-48`, `489`) | None | None |
| `/admin` | `Page/Users/Dashboard.elm` | Section title + 3 rows + footer button (`138-146`) | List | P1 |
| `/admin/users/new` | `Page/Users/CreateUser.elm` | No page fetch (`183`) | None | None |
| `/admin/users/:id/edit` | `Page/Users/EditUser.elm` | Card rows 5 + button (`459-462`) | Settings/detail form | P0 |
| `/foods/custom` | `Page/CustomFood/List.elm` | Section header 2 buttons + 3 rows (`202-216`) | List | P2 |
| `/foods/custom/new` | `Page/CustomFood/Create.elm` | No page fetch | None | None |
| `/foods/custom/new/ai` | `Page/CustomFood/Create.elm` | Assistant status card (`Component/FoodAssistant.elm:648-656`) | Keep assistant card | None |
| `/foods/custom/:id` | `Page/CustomFood/Show.elm` | 120 block + bars + card + 2 buttons (`391-407`) | Header section + card | P1 |
| `/foods/custom/:id/edit` | `Page/CustomFood/Edit.elm` | 4 inputs + button (`426-434`) | Editor | P0 |
| `/foods/:id` | `Page/Food/Show.elm` | 120 block + bars + input + button + card (`519-528`) | Panel detail | P1 |
| `/search` | `Page/Food/Search.elm` | Results 3 rows; recents card; barcode card (`1224-1231`, `1290`, `1416`) | Search body/list | P1 |
| `/logs/:id` | `Page/FoodLog/Entry.elm` | Card rows 2 + 3 inputs + button + card rows 3 (`839-848`) | Panel detail | P1 |
| `/logs/new/ad-hoc` | `Page/FoodLog/CreateAdHoc.elm` | No page fetch | None | None |
| `/logs/new/ai` | `Page/FoodLog/CreateWithAi.elm` | Assistant status card | Keep assistant card | None |
| `/meals` | `Page/Meal/List.elm` | Section header button + 3 rows (`182-191`) | List | P2 |
| `/meals/new` | `Page/Meal/Create.elm` | No page fetch | None | None |
| `/meals/:id` | `Page/Meal/Show.elm` | Card rows 2 + section + 3 rows + 3 cards + 2 buttons (`715-731`) | Section detail | P1 |
| `/meals/:id/edit` | `Page/Meal/Edit.elm` | 4 inputs + card + button (`506-515`) | Editor | P0 |
| `NotFound` | `Page.elm` placeholder | Placeholder | None | None |

### 14.2 Corrected facts and reference index

#### Line and control geometry

- `Element.el` text is line-height 1: height = font size. `Element.paragraph` defaults to `size + 5`.
- `Typography` sizes: caption 13, body 16, screen/subsection 20, section 24, page title 32, hero stat 44 (`Ui/Typography.elm:29-93`).
- `truncatedHeader` is a 24px paragraph -> 29px line (`Ui/Typography.elm:135-146`); `wrappedListItemTitle`, `mutedParagraph` and `mutedBodyParagraph` are 16px paragraphs -> 21px lines.
- Text input: label 13 + **no gap** + 44 (`Ui/Input.elm:134-149`). Dropdown: label 13 + 4px gap + 44 (`Ui/Input.elm:609-614`). The old `Skeleton.input` is 48 (`Ui/Skeleton.elm:71-90`).
- Button 48 (`Ui/Button.elm:232-256`); icon button 44 (`Ui/Button.elm:390-403`); checkbox row 44 (`Ui/Input.elm:655-671`).
- Surface card/section/panel body padding 20, spacing 12 (`Ui/Surface.elm:71-77`, `215-321`); section/card radius from tokens.
- `Surface.listRow`/`staticRow`: padding 16, spacing 12, leading slot always 12px (`Ui/Surface.elm:349-436`).
- Hero media: height 118, top padding 38, bottom 20, horizontal 16 Phone / 34 wider (`Ui/DesignTokens.elm:34-56`).
- Category chip 22px (`.ui-chip`, `main.css:174-191`); status/scope badge 21px (13px caption + 4px top/bottom, `Ui/Chip.elm:133-168`).
- Diary status pill 40px (16px body + 12px top/bottom), not 48 (`Page/Diary/Day.elm:684-723`).
- Diary macro labels are body 16, not 13 (`Page/Diary/Day.elm:745-756`); macro row has 1px dividers and 8px spacing.
- Diary date card body spacing 16 (`totalsView`, `602-634`); `calorieHero` spacing 12 (`651-664`).
- Enabled empty Diary slot: 48px button + 12px padding = 72px block (`Page/Diary/Day.elm:1026-1070`).
- Calendar cell height 68 (`Page/Diary/Calendar.elm:326-328`); width is `fillPortion 1` + `equalColumn` (`Ui/MonthCalendar.elm:23-28`, `83-85`). Loaded weekday row + no inter-cell spacing (`Ui/MonthCalendar.elm:13-62`).

#### Structure and state

- Meal Show is not one panel: header `Surface.section` with notes body, separate components section with custom rows, nutrition `Surface.formSection` + preview, bottom actions (`Page/Meal/Show.elm:542-700`). Its header has no subtitle.
- Food Show / Food Log Entry portion form has three controls: meal slot, quantity/unit, notes (`Component/FoodLogForm.elm:259-288`).
- Nutrition Details coverage banner is always present (`Page/NutritionDetails.elm:259-285`, `380-413`); the date header is `surface-0`, overview is after the banner; `View.Nutrients.skeletonCard` is not used by Nutrition Details.
- `Page.isLoading` is exactly `waitingForToday` (`Page.elm:160-162`); `Page.loading` starts `panes = []`, `waitingForToday = True` (`165-171`); `initPreserving` clears panes on `Nothing` (`313-331`).
- `panesForRoute` runs `Page.elm:883-999`; `contextualWorkspace` `1242-1253`; `isMainPane` `1323`; `Page.view` `3112-3120`.
- `Chrome.viewFrame` is in `frontend-web/src/Chrome.elm:126`; `View.Chrome` has `topBarView` (83), `updateBanner` (215), `bottomNavContainer` (429), `drawerOverlay` (494) with a local `isLoadingPage = False` (504-507).
- Bottom nav is Phone-only (`Ui/Common.elm:13-15`); Tablet has no nav and a 24px gutter (`Ui/Workspace.elm:55-70`). `classifyDevice`: <600 Phone, <1440 Tablet, ≤1920 Desktop, else BigDesktop (`Main.elm:252-267`); 1600 is Desktop.
- `Root` is not always Diary: admins are redirected to `AdminDashboard`, unauthenticated users to `AuthLogin`, non-admin authenticated users to `DiaryDay` (`Access.elm:23-70`).
- `Skeleton.card` does have body padding via `Surface.card`; it lacks a tinted header band, hairlines and a footer.
- `Ui.Page.pageHeader` leading is `Maybe`, not `List` (`Ui/Page.elm:39-47`); `pageHeaderRaw` must preserve the empty leading/actions slots.
- `Skeleton.listRow` always has a 12px leading slot, even when `leading = []`.
- Existing `View.Nutrients.skeletonPreview` (`273-286`) is used by `preview`; add/rename `skeletonCard` for `nutritionCard` and make `preview` reuse it.
- Meal Show's current skeleton has three `Skeleton.card`s (`Page/Meal/Show.elm:715-731`), not two.

#### Harness / env facts

- `capture-readme-screenshots.mjs` uses `CALCO_SCREENSHOT_DATE` (line 22), default `2026-10-27`; the new harness uses `CALCO_LAYOUT_DATE`.
- `Version` fetches `/version.json?v=...` (`Version.elm:100`), which is not under `/api/*`; intercept it separately.
- `justfile` line-length check is `rg -n '.{101,}'` at `149-154`; target 100 columns. `check-frontend` is line 144; `screenshots` is 102-103.
- `docs/testing.md:98-99` prohibits DOM/CSS assertions in elm-test UI tests; the browser harness is separate and the ARIA render test is allowed with a justification comment.
- `docs/qa-runbook.md:15` uses 375x667; the harness uses 390x844 as a modern Phone plus 360/320 narrow cases. State the difference; both are Phone.
- Backend has no user-delete route; only list/get/create/reset/disable/enable (`backend/src/auth/api/http.rs:31-45`). `admin_create_user_handler` does not set a session cookie (`466-482`). Use a disposable DB/schema or a reusable layout user; disable and record.
- There is no CI config in the repo today; start report-only/nightly/manual. If a required job is added, always require Chrome (`CALCO_REQUIRE_LAYOUT=1`) and never silently skip.
