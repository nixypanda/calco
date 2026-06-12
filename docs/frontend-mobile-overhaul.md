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

## Phase 2: Navigation (bottom tab bar on phone)

### 2.1 Bottom navigation for Phone

**File:** `src/Main.elm`

Replace/supplement hamburger drawer with a bottom tab bar when `isSmall` is true.

Tabs (matching current drawer items):
1. Diary (house icon or "Diary" text)
2. Search Foods (magnifying glass or "Search" text)
3. My Foods (fork/knife or "Foods" text)
4. My Meals (plate or "Meals" text)

Structure in `appFrame`:

```
Element.column [fill, fill]
  topBarView (58px)
  pageView (fill remaining)
  bottomNavBar (only on phone, ~56px)
```

The hamburger drawer remains accessible from the top bar on phone for profile/logout/admin, but primary navigation moves to the bottom bar.

### 2.2 Bottom nav bar styling

- Fixed 56px height
- 4 equal-width columns using `Element.row` + `fillPortion 1`
- Each column: icon (unicode char) + 12px label below
- Active tab: `brandBlue` color + bottom accent line (2px)
- Inactive tabs: `textMuted` color
- Uses `Input.button` for tap handling

---

## Phase 3: Diary Day Page

**File:** `src/Page/Diary/Day.elm`

### 3.1 Date navigation

Current: `← Date →` row with 40px icon buttons and centered date text.

Changes on phone:
- Increase icon buttons to 44×44 (handled by Phase 1.2)
- Increase date text font from `sizeSubsectionTitle` (17px) to `sizeSectionTitle` on phone
- Reduce horizontal padding in date card from 12px to match `pageContainer` phone padding

### 3.2 Macro bar density

Current: 4 stacked `macroBar` components (calories, protein, carbs, fat), each showing label, value, and a 10px progress bar.

On phone, condense to show only 2 rows:
- Row 1: Calories (with progress bar)
- Row 2: Protein / Carbs / Fat in a 3-column row with value only (no bar)

This reduces vertical scroll while keeping key data visible.

### 3.3 Meal slot cards

Current: 118px header with background image, fade gradient, and content overlaid.

On phone:
- Reduce `mealSlotHeaderHeight` from 118px to 80px
- Move kcal label into the same row as section title (currently on the right of the row — keep this)
- Keep the background image but crop tighter
- Increase "+ Add Food" button padding from ghostButton default to ensure ≥ 44px height

### 3.4 Log entry rows

Current: `Input.button` with `row` containing macroDot + truncated name + quantity caption + kcal caption.

On phone:
- Change to `wrappedRow` or use `column` for the content area if the row overflows
- Increase padding from 14px to 16px
- Show quantity and kcal on a second line below the food name

---

## Phase 4: Food Search & Logging

### 4.1 Category pills — reflow instead of hide

**File:** `src/View/Search.elm` (`resultRow`)

Current: pills are completely removed on phone (`if isSmall then []`).

On phone, render pills below the item content instead of to the right:
- Move from a `row` to a `column` layout on phone
- Pills wrap in a `wrappedRow` below the item title
- Use full width instead of fixed 160px column
- Keep pill size at 13px font (already small enough)

### 4.2 Search input improvements

**File:** `src/View/Search.elm` (`searchInput`)

- Increase input padding to 14px on phone (from 12px)
- Completion dropdown: make items 44px height on phone (from 38px) via `completionDropdownHeight`
- Add `Element.padding 14` to completion rows on phone

### 4.3 Food detail & log form

**Files:** `src/Page/Food/Show.elm`, `src/Page/FoodLog/Form.elm`

Log form card:
- Already uses column layout — good
- Increase spacing from `space16` to `space16` (already correct)
- Make "Log Food" button: full width + 56px height on phone
- Add `Element.paddingEach { top = 0, right = 0, bottom = env(safe-area-inset-bottom), left = 0 }` below the submit button on phone for home indicator clearance

Nutrition card (`View/Nutrients.elm`):
- `nutrientsTableInner`: on phone, merge Amount + Unit columns into one ("Amount Unit") to save horizontal space
- `macroBreakdownView`: on phone, show the macro legend as a single condensed row with percentage values only (currently `Element.none` on phone)

### 4.4 Quantity input

**File:** `src/View/QuantityInput.elm`

Already uses `Element.column` on phone. No changes needed.

---

## Phase 5: Custom Food & Meal CRUD Forms

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
- Make "+" add button (iconButton) ensure 44×44 target size

Submit button:
- Full width, 56px height on phone

### 5.2 Meal form

**File:** `src/Page/Meal/Form.elm`

Component row (`componentRowView`):
- Search input + results + qty row + remove button — already stacks vertically
- Search results items: ensure 44px touch targets
- Remove button: ensure 44×44

Quantity text input (`quantityTextInput`):
- Already switches to `Element.column` on phone. Keep this.

"+ Add Component" button:
- Full width, taller on phone

### 5.3 Generic form patterns

Throughout all form pages:
- All `Ui.section` / `formSection` cards: reduce internal padding from 20px to 16px on phone
- All submit/primary buttons: `width fill` + 56px height on phone
- All error banners: ensure they wrap text properly on narrow screens

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
| 2.0 | ~3hr | High | Bottom navigation for phone | |
| 3.1-3.4 | ~3hr | High | Diary page improvements | |
| 4.1-4.4 | ~3hr | High | Search & logging improvements | |
| 5.1-5.3 | ~4hr | High | Form page improvements | |
| 6.0 | ~4hr | Low | Touch interactions (swipe, pull-to-refresh) | |
| 7.0 | ~2hr | Medium | Tablet support | |

**Core overhaul (Phases 1-5): ~18 hours**
**Full overhaul (Phases 1-7): ~24 hours**
**Phase 1 actual: ~2.5 hours**

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
