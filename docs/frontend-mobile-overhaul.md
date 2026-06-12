# Frontend Mobile & Touchscreen Overhaul

## Current State

The app is **desktop-first** with minimal mobile accommodation:

- `meta viewport` tag is present, `Element.classifyDevice` (Phone/Tablet/Desktop) is used and updated on resize
- Only **one** responsive check exists: `isSmall` (phone vs not-phone)
- All layouts are fixed `column`/`row` with no breakpoint reflow
- Font sizes, spacing, and tap targets are hardcoded in px
- ~~`mouseOver` hover effects on every button/dropdown — stuck on touch devices~~ **Fixed in Phase 1**
- Category pills hidden entirely on phone instead of being reflowed
- Macro legend hidden on phone instead of being reflowed
- ~~No safe area handling for notched devices~~ **Fixed in Phase 1**
- No bottom navigation for phone form factor

## Target Pages

1. **Diary Day** (home) — date nav, macro bars, meal slot cards with log entries
2. **Food Search & Logging** — search bar, category pills, food results, log form
3. **Custom Food / Meal CRUD** — forms with nutrient tables, serving sizes, component rows

---

## Phase 1: Core Infrastructure (touch-friendly baseline) ✅ COMPLETE

### 1.1 Fix stuck hover states ✅

**Files:** `src/Ui.elm` (buttons, iconButton, dangerIconButton, chipView, selectDropdown, ghostButton)

All buttons and interactive elements use `Element.mouseOver` to show a hover background change. On touch devices, the first tap activates the hover style (stuck state) and a second tap is needed to activate the button.

Approach: Skip `mouseOver` styling entirely on Phone class, or add `Element.mouseDown` alongside `mouseOver` so both mouse and touch users see visual feedback.

Components affected:
- `button` — `mouseOver [ Background.color theme.brandBluePressed ]`
- `primarySubmitButton` — `mouseOver [ Background.color theme.brandBluePressed ]`
- `dangerButton` — `mouseOver [ Background.color theme.dangerFg ]`
- `ghostButton` — `mouseOver [ Background.color theme.brandBlueSoft ]`
- `iconButton` — `mouseOver [ Background.color theme.brandBlueSoft, Border.color theme.brandBlue ]`
- `dangerIconButton` — `mouseOver [ Background.color theme.dangerSolid, ... ]`
- `selectDropdown` trigger — `mouseOver [ Border.color theme.brandBlue ]`
- `chipView` remove button — `mouseOver [ Background.color theme.dangerSolid, ... ]` (deferred to Phase 4)

**Implementation:** Created `Ui.hoverEffect : Element.Device -> List Element.Decoration -> Element.Attribute msg` that returns `Element.mouseOver []` on Phone, otherwise applies the given `mouseOver` attrs. Added `Device` parameter to all affected button functions and updated all call sites across 22 files.

### 1.2 Bump tap targets to 44px minimum ✅

**File:** `src/Ui.elm`

Apple HIG recommends 44×44pt minimum tap targets. Current sizes:

| Component | Before | After |
|-----------|--------|-------|
| `iconButton` | 40×40 | 44×44 |
| `dangerIconButton` | 40×40 | 44×44 |
| `button` | 12+18+12+18 padding (~38px) | 14+18+14+18 (~46px) |
| `ghostButton` | 8+14+8+14 padding (~30px) | 10+16+10+16 (~42px) |
| `primarySubmitButton` | 14+20+14+20 (~48px) | OK as-is |
| `selectDropdown` option | `paddingXY 14 10` (~38px) | `paddingXY 14 12` (~42px) |

`chipView` remove button (18×18 → 28×28) deferred to Phase 4.

### 1.3 Add Device-aware layout helpers ✅

**File:** `src/Ui.elm`

Add helpers beyond the existing `isSmall`:

```elm
isSmall : Element.Device -> Bool   -- already exists
onPhone : Device -> a -> a -> a    -- added
hoverEffect : Device -> List Decoration -> Attribute msg  -- added
```

**Note:** `isMedium` and `isDesktop` were omitted from this phase since nothing uses them yet. They can be added in Phase 7 (tablet support) when needed.

### 1.4 Safe area padding ✅

**File:** `index.html`

Add `env(safe-area-inset-*)` to account for notched devices and the home indicator:

```css
body {
  margin: 0;
  padding-top: env(safe-area-inset-top);
  padding-left: env(safe-area-inset-left);
  padding-right: env(safe-area-inset-right);
  padding-bottom: env(safe-area-inset-bottom);
}
```

Also update `viewport` meta tag to include `viewport-fit=cover`:

```html
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
```

### 1.5 Responsive font sizing ✅

**File:** `src/Ui.elm`

Title wrappers (`pageTitle`, `sectionTitle`, `subsectionTitle`) now accept `Device` and use `onPhone` for responsive sizing:

| Wrapper | Desktop | Phone |
|---------|---------|-------|
| `pageTitle` | 28px | 24px |
| `sectionTitle` | 22px | 18px |
| `subsectionTitle` | 17px | 15px |

`body` and `caption` remain static (14px and 12px). `bodyFor`/`captionFor` deferred to later phases when phone-specific body text is needed.

---

## Phase 2: Navigation (bottom tab bar on phone) ✅ COMPLETE

### 2.1 Bottom navigation for Phone ✅

**File:** `src/Main.elm`

Replace hamburger drawer with a fixed bottom tab bar on phone for non-admin users. The drawer is fully disabled on phone for non-admins — the bottom bar is a complete replacement.

Tabs (matching current drawer items):
1. Diary (`⌂` icon)
2. Search Foods (`🔍︎` icon)
3. My Foods (`◉` icon)
4. My Meals (`🍽` icon)

Structure in `appFrame`:

```
Element.column [fill, fill]
  topBarView (58px)
  pageView (fill remaining, 56px bottom padding when nav visible)
  bottomNavBar (fixed, inFront, ~56px)
```

The `appFrame` function computes `useBottomNav` once and uses it to:
- Switch between bottom nav (`Element.inFront`) and drawer overlay (`drawerOverlay`)
- Add 56px bottom padding to page content

Admin users keep the drawer on all devices. Login/bootstrap pages show no chrome.

### 2.2 Bottom nav bar styling ✅

- Fixed 56px height, `position: fixed; bottom: 0; z-index: 10`
- 4 equal-width columns using `Element.row` + `fillPortion 1`
- Each column: icon (unicode char) + 11px label below
- Active tab: `brandBlue` color + 2px top accent line
- Inactive tabs: `textMuted` color
- Uses `Input.button` with `NavigateTo` message
- Active detection reuses existing `primaryRoute` function

### 2.3 Top bar adjustments ✅

`screenMeta` now takes `Device` and `Session` parameters. On phone for non-admin users, primary routes (`DiaryDay`, `FoodSearch`, `CustomFoodList`, `MealList`, `Root`) return `NoLeadingAction` instead of `OpenMenu`, removing the hamburger button. Sub-pages keep `GoBack` arrows. Profile/logout remains accessible via the existing `profileButton` dropdown in the top bar.

### 2.4 Drawer disabled on phone for non-admins ✅

`drawerOverlay` no longer checks `showBottomNav` — it just checks `drawerOpen && showsAppChrome`. The mutual exclusion is handled entirely in `appFrame` via the `useBottomNav` flag.

---

## Phase 3: Diary Day Page

**File:** `src/Page/Diary/Day.elm`

### 3.1 Date navigation

Current: `← Date →` row with 40px icon buttons and centered date text.

Changes (all screen sizes):
- Always use `Ui.sectionTitle` for the date text (18px phone / 22px desktop), replacing `Ui.subsectionTitle`

### 3.2 Macro bar density

No changes needed. The 4 stacked macro bars look fine on mobile as-is.

### 3.3 Meal slot cards

No changes needed. The 118px header height is required for the background image. The `+ Add Food` ghostButton already has ≥44px tap targets from Phase 1.2.

### 3.4 Log entry rows

No changes needed. The current row layout with truncation works well on mobile.

---

## Phase 4: Food Search & Logging ✅ COMPLETE

### 4.1 Category pills — reflow instead of hide ✅

**File:** `src/View/Search.elm` (`resultRow`, `categoryPills`)

On phone, pills render below the item content using `Element.wrappedRow` (full width) instead of being hidden. Desktop keeps the 160px right-aligned column layout. `categoryPills` now takes `Device` as its third parameter.

### 4.2 Search input improvements ✅

**File:** `src/View/Search.elm` (`searchInput`, `completionDropdownHeight`, `completionRow`)

- `searchInput` now takes `Device` as second parameter
- Input padding: 14px on phone, 12px on desktop
- `completionDropdownHeight`: 44px rows on phone (from 38px), 38px on desktop
- `completionRow`: 14px padding on phone, `paddingXY 12 10` on desktop

### 4.3 Food detail & log form ✅

**File:** `src/Page/Food/Show.elm`

Log form card:
- "Log Food" button gets `calc(14px + env(safe-area-inset-bottom))` bottom padding on phone for home indicator clearance
- Nutrition card changes deferred (card looks fine as-is on mobile)

### 4.4 Quantity input

**File:** `src/View/QuantityInput.elm`

Already uses `Element.column` on phone. No changes needed.

---

## Phase 5: Custom Food & Meal CRUD Forms ✅ COMPLETE

### 5.1 Custom Food form

**File:** `src/Page/CustomFood/Form.elm`

Nutrient row (`nutrientRowView`):
- Currently: horizontal row with 4 elements (nutrient dropdown, amount input, unit label, remove button)
- On phone: stack vertically — full-width nutrient dropdown, then a row with amount + unit + remove button
- Each `Ui.input` gets full width on phone

Serving row (`servingRowView`):
- Already uses vertical `column` layout. Good.
- On phone: stack the qty/unit/grams row vertically (currently `Element.row` with 3 inputs + remove button)
- Make remove button bigger and more accessible

Category input:
- Already has `wrappedRow` for chips. Good.
- Make "+" add button (iconButton) ensure 44×44 target size ✅

Submit button:
- Full width, 56px height on phone ✅

### 5.2 Meal form

**File:** `src/Page/Meal/Form.elm`

Component row (`componentRowView`):
- Search input + results + qty row + remove button — already stacks vertically
- Search results items: ensure 44px touch targets ✅
- Remove button: ensure 44×44 ✅

Quantity text input (`quantityTextInput`):
- Already switches to `Element.column` on phone. Keep this.

"+ Add Component" button:
- Full width ✅

### 5.3 Generic form patterns

Throughout all form pages:
- All submit/primary buttons: `width fill` + 56px height on phone ✅
- All error banners: ensure they wrap text properly on narrow screens ✅

### 5.4 Touch-friendly remove buttons

Category chip remove button:
- 28×28 on phone (from 18×18) ✅
- Uses `hoverEffect` for touch-safe feedback ✅

Row action buttons (nutrient/serving remove):
- 44px width for minimum tap target ✅

### Deferred

- Nutrient row vertical stacking on phone (deferred to Phase 6+)
- Serving row qty/unit/grams vertical stacking on phone (deferred to Phase 6+)
- Form section card padding reduction on phone (deferred when needed)
- Swipe-to-remove on nutrient/serving rows (Phase 6+)

---

## Phase 6: Touch Interactions (stretch / polish)

### 6.1 Swipe-to-navigate on diary date

On phone only, detect horizontal swipe gestures on the date card:
- Track `touchstart` / `touchend` X coordinates via `Html.Events.preventDefaultOn "touchstart"` + port-based event listener
- If swipe delta > 80px horizontally: trigger `PreviousDayClicked` or `NextDayClicked`
- Show a subtle animation hint (slide card left/right)

### 6.2 Pull-to-refresh

On the diary page:
- Detect overscroll on the main content area
- Show a loading spinner at the top
- Trigger `RequestDiaryData` for the current date

### 6.3 Drawer swipe-to-close

On phone, when the drawer is open:
- Detect right-to-left swipe on the overlay area
- Close the drawer

---

## Phase 7: iPad / Tablet Support

### 7.1 Tablet-aware layouts

Add `isMedium` helper (see Phase 1.3) that's true for Tablet class.

On tablet:
- Diary: 2-column grid — macro totals card on the left, meal slots on the right
- Food detail: side-by-side food info card + log form
- Keep the top bar + drawer navigation (no bottom tab bar)

### 7.2 Width constraints

- Tablet: `pageContainer` max-width stays at 960px but uses more horizontal space
- Tablet stat blocks: 3 per row instead of 2 (in `Ui.statBlockGroup`)

---

## Execution Order

| Step | Effort | Impact | Description | Status |
|------|--------|--------|-------------|--------|
| 1.1 | ~1hr | High | Fix stuck hover states | ✅ Done |
| 1.2 | ~30min | High | Bump tap targets to 44px | ✅ Done |
| 1.3 | ~30min | Medium | Add Device-aware helpers | ✅ Done |
| 1.4 | ~30min | Medium | Safe area padding | ✅ Done |
| 1.5 | ~1hr | Medium | Responsive font sizing | ✅ Done |
| 2.0 | ~3hr | High | Bottom navigation for phone | ✅ Done |
| 3.1 | ~5min | High | Date text uses `sectionTitle` | ✅ Done |
| 3.2-3.4 | — | — | Macro bars, meal headers, log rows — no changes needed | ✅ Skipped |
| 4.1-4.4 | ~3hr | High | Search & logging improvements | ✅ Done |
| 5.1-5.3 | ~1.5hr | High | Form page improvements | ✅ Done |
| 6.0 | ~4hr | Low | Touch interactions (swipe, pull-to-refresh) | |
| 7.0 | ~2hr | Medium | Tablet support | |

**Core overhaul (Phases 1-5): ~15 hours**
**Full overhaul (Phases 1-7): ~21 hours**
**Phase 1 actual: ~2.5 hours**
**Phase 3 actual: ~5 minutes**
**Phase 4 actual: ~1.5 hours**
**Phase 5 actual: ~1.5 hours**

---

## Quality Gates

Before committing changes, run from the repository root:

```bash
just frontend-web-line-length
just frontend-web-review
just frontend-web-test
just frontend-web-format
```

All existing tests should pass. No new tests are strictly required for UI-only changes, but any new `Device`-aware logic in `Ui.elm` helpers should be tested.

---

## Phase 1 Changelog

### Breaking API changes

The following functions now require `Device` as their first parameter:
- `Ui.button`
- `Ui.primarySubmitButton`
- `Ui.dangerButton`
- `Ui.ghostButton`
- `Ui.iconButton`
- `Ui.dangerIconButton`
- `Ui.selectDropdown`
- `Ui.formSection`
- `Ui.pageTitle`
- `Ui.sectionTitle`
- `Ui.subsectionTitle`
- `View.QuantityInput.dropdown`
- `Page.FoodLog.Form.view`

### Files modified (22 files)

| File | Changes |
|------|---------|
| `src/Ui.elm` | Added `onPhone`, `hoverEffect`; added `Device` param to 10 functions; bumped tap targets; responsive font sizes in title wrappers |
| `index.html` | `viewport-fit=cover`, safe-area-inset padding |
| `src/Main.elm` | Pass `device` to Ui button/icon/title functions |
| `src/Page/Diary/Day.elm` | Pass `device` to Ui button/icon/title functions |
| `src/Page/Food/Search.elm` | Pass `device` to `Ui.button` |
| `src/Page/Food/Show.elm` | Pass `device` to `Ui.primarySubmitButton`, `Ui.iconButton`, `FoodLogForm.view` |
| `src/Page/FoodLog/Entry.elm` | Pass `device` to `Ui.primarySubmitButton`, `Ui.iconButton`, `Ui.dangerIconButton`, `FoodLogForm.view` |
| `src/Page/FoodLog/Form.elm` | Added `Device` import, added `Device` param to `view` and `mealSlotDropdown` |
| `src/Page/Meal/Show.elm` | Pass `device` to Ui button/icon/title functions, `QuantityInput.dropdown` |
| `src/Page/Meal/Form.elm` | Pass `device` to `Ui.ghostButton`, `Ui.dangerIconButton`, `Ui.subsectionTitle` |
| `src/Page/Meal/List.elm` | Pass `device` to `Ui.ghostButton`, `Ui.iconButton`, `Ui.dangerIconButton` |
| `src/Page/Meal/Edit.elm` | Pass `device` to `Ui.primarySubmitButton` |
| `src/Page/Meal/Create.elm` | Pass `device` to `Ui.primarySubmitButton` |
| `src/Page/CustomFood/List.elm` | Pass `device` to `Ui.ghostButton`, `Ui.iconButton`, `Ui.dangerIconButton` |
| `src/Page/CustomFood/Form.elm` | Threaded `Device` through `view`, `basicInfoCard`, `nutrientsCard`, `servingsCard`, `portionInfoCard`, `categoryInputView`, `addCategoryButton`, `nutrientRowView`, `servingRowView`, `rowActionButton` |
| `src/Page/CustomFood/Edit.elm` | Pass `device` to `Ui.primarySubmitButton` |
| `src/Page/CustomFood/Create.elm` | Pass `device` to `Ui.primarySubmitButton` |
| `src/Page/Users/EditUser.elm` | Threaded `Device` through `userInfoView`, `resetPasswordView`, `enableDisableView`, `userSummaryCard` |
| `src/Page/Users/CreateUser.elm` | Pass `device` to `Ui.button` |
| `src/Page/Users/CredentialForm.elm` | Pass `device` to `Ui.primarySubmitButton`, `Ui.pageTitle`, `Ui.subsectionTitle` |
| `src/Page/Users/Dashboard.elm` | Threaded `Device` through `bodyView`, `userListRow` |
| `src/View/Nutrients.elm` | Pass `device` to `Ui.subsectionTitle` |
| `src/View/QuantityInput.elm` | Added `Device` import, added `Device` param to `dropdown` |
| `tests/UiTest.elm` | Pass `phone` to `Ui.iconButton`, `Ui.dangerIconButton` |

---

## Phase 2 Changelog

### Breaking API changes

- `screenMeta` now takes `Device` and `Session` as first two parameters (internal to `Main.elm`, not a public API)

### New functions

- `showBottomNav : Model -> Bool` — returns `True` when on phone, chrome is shown, and user is not admin
- `bottomNavBar : Model -> Element Msg` — renders the fixed bottom tab bar
- `tabButton : Model -> String -> String -> Route -> Element Msg` — renders a single tab in the bottom bar

### Behavioral changes

- On phone for non-admin users: bottom nav bar is shown, drawer is disabled, hamburger button is removed from primary pages
- Admin users: no bottom nav, drawer remains as-is on all devices
- Login/bootstrap pages: no chrome shown (unchanged)
- Profile/logout: still accessible via `profileButton` dropdown in top bar

### Files modified (1 file)

| File | Changes |
|------|---------|
| `src/Main.elm` | Added `showBottomNav`, `bottomNavBar`, `tabButton`; updated `appFrame` to compute chrome attrs once; updated `screenMeta` to take `Device` and `Session`; simplified `drawerOverlay` |

---

## Phase 4 Changelog

### Breaking API changes

- `View.Search.searchInput` now takes `Device` as second parameter
- `View.Search.completionDropdownHeight` now takes `Device` as first parameter
- `View.Search.completionRow` now takes `Device` as second parameter

### Behavioral changes

- Category pills on phone: reflow as `wrappedRow` below item content instead of being hidden
- Search input on phone: 14px padding (from 12px)
- Completion dropdown rows on phone: 44px height with 14px padding (from 38px with `paddingXY 12 10`)
- "Log Food" button on phone: bottom safe-area padding for home indicator clearance

### Files modified (4 files)

| File | Changes |
|------|---------|
| `src/View/Search.elm` | Added `Device` to `searchInput`, `completionDropdownHeight`, `completionRow`; reflow `categoryPills` on phone using `Element.wrappedRow` instead of hiding |
| `src/Page/Food/Search.elm` | Thread `Device` through `searchInputView` |
| `src/Page/Meal/Form.elm` | Pass `Device` to `SearchView.searchInput` |
| `src/Page/Food/Show.elm` | Add `Html.Attributes` import; safe-area bottom padding on phone for Log Food button |

---

## Phase 5 Changelog

### Breaking API changes

- `chipView` now takes `Device` as second parameter (internal to `Page.CustomFood.Form`)
- `chipRowView` now takes `Device` as second parameter (internal to `Page.CustomFood.Form`)

### New functions

- `hoverEffect` exposed from `Ui` module

### Behavioral changes

- All primary submit buttons (Create Food, Save Food, Create Meal, Update Meal): 56px height on phone (from auto)
- Category chip remove button: 28×28 on phone (from 18×18)
- Row action buttons (nutrient/serving remove): 44px width (from 40px)
- "+ Add Component" button in meal form: full width on all devices (was not full width)
- Chip remove buttons use `hoverEffect` for touch-safe feedback

### Files modified (3 files)

| File | Changes |
|------|---------|
| `src/Ui.elm` | Exposed `hoverEffect`; added 56px height on phone to `primarySubmitButton` |
| `src/Page/CustomFood/Form.elm` | `chipView`/`chipRowView` now take `Device`; remove button 28×28 on phone; `rowActionButton` 44px width; `hoverEffect` instead of `mouseOver` |
| `src/Page/Meal/Form.elm` | "+ Add Component" uses `fullWidthGhostButton` |
