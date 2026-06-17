# Visual Consistency Audit

## Summary

This audit covers the active Elm frontend in `frontend-web/` and focuses on
how consistently the codebase applies typography, color semantics, containers,
actions, navigation chrome, and data-entry patterns.

The shared UI layer is already stronger than average for a small app:

- `src/Ui.elm` centralizes most spacing, radius, card, button, input, and
  status primitives.
- `src/Ui/Theme.elm` provides a real light/dark token set.
- `src/main.css` is scoped to global motion, focus, chip, toggle, and shell
  behavior instead of becoming a second ad hoc styling system.

The main consistency problems are systemic rather than random:

- action placement and emphasis drift by screen,
- some data-heavy surfaces bypass the shared list and picker patterns.

## Findings

### Note: System-native typography is an acceptable default

**Evidence**

- `frontend-web/src/Ui.elm:354-360` sets the app font family to `Inter`.
- `frontend-web/src/main.css:3-10` also sets the document shell to `Inter`.
- `public/` contains icons and meal images, but no bundled font assets.

**Why this is acceptable**

The repo does not currently ship or import `Inter`, so the app falls back to
the host platform sans-serif. That does mean minor differences in spacing,
weight, and wrapping by browser and OS, but if the product decision is that
system-native text is fine, this is not a visual-consistency defect that needs
to be prioritized.

The remaining concern is mostly one of clarity: the code currently names
`Inter` as if it were a guaranteed brand choice, while the actual runtime
behavior is system-native text.

This is worth keeping in mind because the app still relies on:

- tight truncation in `Ui.truncatedHeader` and `Ui.truncatedListItemTitle`,
- compact top-bar chrome in `Main.topBarView`,
- narrow chip and badge treatments in `Ui.chip` and `Ui.badge`.

**Recommended direction**

- Treat system-native text as intentional unless branding requirements change.
- If desired, update the code comments or font declaration to reflect that the
  app is intentionally using the platform default rather than a bundled font.
- Re-check truncation and list density only if the team later decides to lock a
  specific typeface.

### Done: Iconography is now locked to a shared SVG icon system

**Evidence**

- Shared icons now live in `frontend-web/src/Ui/Icon.elm`.
- Navigation and chrome buttons consume `Icon` values through shared button
  primitives in `frontend-web/src/Main.elm:1441-1446`,
  `frontend-web/src/Main.elm:1640-1642`, and
  `frontend-web/src/Ui.elm:1685-1774`.
- Select controls and remove actions also use the same icon system in
  `frontend-web/src/Ui.elm:1564-1571`,
  `frontend-web/src/Ui.elm:1856-1860`,
  `frontend-web/src/Page/CustomFood/Form.elm:923-927`,
  `frontend-web/src/Page/CustomFood/Form.elm:1027-1031`, and
  `frontend-web/src/Page/Meal/Form.elm:698-702`.

**Why this is improved**

The app no longer depends on platform text glyphs or emoji for primary
navigation and core form affordances. That removes a major source of
cross-platform drift in baseline, stroke weight, and color treatment.

**Follow-up**

- Keep new icons flowing through `Ui.Icon` and the shared button/select
  primitives rather than introducing one-off inline SVG or text glyphs.

### Done: Theme coverage now owns the major semantic accents

**Evidence**

- `frontend-web/src/Ui/Theme.elm` now defines theme-owned semantic fields for
  chip-selected colors, focus ring, calories, and macro accents.
- `frontend-web/src/Ui.elm` now resolves chip-selected state, focus-ring CSS
  variables, and macro color lookup from `Theme`.
- Nutrition and diary surfaces consume those theme-owned colors in
  `frontend-web/src/View/Nutrients.elm` and
  `frontend-web/src/Page/Diary/Day.elm`.
- `frontend-web/tests/UiTest.elm` now asserts the theme-backed chip, focus, and
  macro color behavior.

**Why this is improved**

The most visible semantic accents no longer bypass the light/dark theme model:

- macro dots and bars,
- selected chips,
- focus ring,
- calorie highlight.

That means dark mode can tune those accents independently instead of inheriting
light-mode values by accident, and the CSS bridge now reads from the same theme
source of truth as the Elm UI primitives.

**Follow-up**

- Keep new semantic accents flowing through `Ui.Theme.Theme` rather than adding
  fresh module-level color constants in `Ui.elm`.
- Treat future progress, selection, or emphasis colors as theme-owned by
  default unless they are intentionally decorative.

### Medium: Action hierarchy and placement change from screen to screen

**Evidence**

- Auth keeps submit actions inside the card in
  `frontend-web/src/Page/Users/CredentialForm.elm:130-153`.
- User creation also keeps Save inside the card in
  `frontend-web/src/Page/Users/CreateUser.elm:189-208`.
- Goals moves the submit action outside the card in
  `frontend-web/src/Page/Goals/Settings.elm:286-319`.
- Meal and custom-food create/edit screens place full-width submit actions below
  the form content in
  `frontend-web/src/Page/Meal/Create.elm:123-132`,
  `frontend-web/src/Page/Meal/Edit.elm:388-399`,
  `frontend-web/src/Page/CustomFood/Create.elm:192-201`, and
  `frontend-web/src/Page/CustomFood/Edit.elm:342-351`.
- Food logging uses `Ui.cardActions` plus a safe-area wrapper in
  `frontend-web/src/Page/Food/Show.elm:406-430`.
- Destructive modals style `Cancel` as a primary action in
  `frontend-web/src/Page/Meal/Show.elm:687-698`,
  `frontend-web/src/Page/CustomFood/Show.elm:393-404`, and
  `frontend-web/src/Page/FoodLog/Entry.elm:857-868`.

**Why this is inconsistent**

The app has several valid CTA patterns, but they are not applied consistently:

- primary action inside card,
- primary action below card,
- full-width footer action,
- paired bottom action buttons,
- modal cancel styled the same way as a positive primary CTA.

That makes it harder to predict where the main action lives and how strong each
action should feel.

**Recommended direction**

- Standardize one action model per screen type:
  auth/setup, form-create/edit, detail-with-destructive-actions, modal confirm.
- Introduce a true secondary modal action style for `Cancel`.
- Prefer one shared footer/action-slot pattern rather than mixing `Ui.button`,
  `Ui.primarySubmitButton`, `Ui.cardActions`, and `Ui.bottomActionButtons`
  based only on page history.

### Done: Heading scale and hierarchy are now consistent

**Evidence**

- The typography scale was reworked to use fixed sizes per heading level,
  removing Device-specific font size switching from `pageTitle`, `sectionTitle`,
  `subsectionTitle`, and `truncatedHeader`.
- `Ui.truncatedHeader` now uses the same `sizeSectionTitle` as other section
  headings, and no longer takes a `Device` parameter.
- Admin list rows in `frontend-web/src/Page/Users/Dashboard.elm` and user
  summary cards in `frontend-web/src/Page/Users/EditUser.elm` now use
  `Ui.listItemTitle` instead of `Ui.sectionTitle`, giving row content the
  correct typographic weight.
- The base body font size was bumped from 14px to 16px, fixing iOS Safari
  auto-zoom on input focus.

**Why this is improved**

- Heading hierarchy is now uniform: page titles (32px), section titles (24px),
  subsection titles (20px), body (16px).
- `pageTitle`, `sectionTitle`, and `subsectionTitle` are reserved for true
  structural headings.
- `listItemTitle` provides an intermediate weight for row-level content without
  borrowing heading semantics.
- Removing Device-specific font sizes simplified function signatures across 17
  files and eliminated a class of unused-parameter warnings.

**Follow-up**

- Keep new heading usage flowing through `pageTitle`, `sectionTitle`,
  `subsectionTitle`, or `listItemTitle` depending on semantic role.

### Medium: Search and picker surfaces bypass the shared list and input language

**Evidence**

- Search results render custom button rows instead of `Ui.listRow` in
  `frontend-web/src/View/Search.elm:78-129`.
- Desktop search results use a separate fixed-width category-pill column in
  `frontend-web/src/View/Search.elm:180-238`.
- The app has at least three different dropdown/suggestion shells:
  `Ui.completionDropdown` in `frontend-web/src/Ui.elm:1416-1435`,
  `Ui.suggestionList` in `frontend-web/src/Ui.elm:1467-1482`, and
  `Ui.selectDropdown` in `frontend-web/src/Ui.elm:1485-1599`.
- Category suggestions in the custom-food form use a fourth visual pattern via
  custom `Input.button` rows in
  `frontend-web/src/Page/CustomFood/Form.elm:843-889`.

**Why this is inconsistent**

The codebase has a decent shared form and list system, but search and picker UI
is still fragmented:

- search results are list-like but not styled like the other list surfaces,
- suggestion overlays differ in border, shadow, padding, and selected-state
  treatment,
- option rows are implemented in multiple styles with no single canonical
  chooser pattern.

These are exactly the kinds of surfaces where small divergences become very
visible during day-to-day use.

**Recommended direction**

- Create one canonical “option list” family for search completions, category
  suggestions, and select dropdown menus.
- Either adapt `Ui.listRow` for search results or introduce a shared
  `searchResultRow` primitive with the same spacing and title rules as list rows.
- Normalize overlay treatment: border versus shadow, row padding, active state,
  and badge placement.

### Medium: App chrome intentionally changes by route and device, but the visual system does not smooth the transitions

**Evidence**

- The bottom nav only appears for small non-admin authenticated screens in
  `frontend-web/src/Main.elm:1292-1297`.
- Primary phone routes suppress the leading menu button in
  `frontend-web/src/Main.elm:1453-1529`.
- Desktop/admin navigation uses a drawer in
  `frontend-web/src/Main.elm:1551-1607`.
- Login and setup still render the top bar shell with only the theme toggle in
  `frontend-web/src/Main.elm:1360-1376`.

**Why this is inconsistent**

The chrome changes are product-driven, but they still produce abrupt visual mode
switches:

- phone primary routes: bottom nav + no leading action,
- phone sub-routes: back arrow + no bottom-nav context in the header,
- desktop non-admin: back or drawer depending on route,
- auth/setup: blank top bar plus a lone theme switch.

The system works functionally, but it does not read as one coherent navigation
language.

**Recommended direction**

- Define explicit chrome variants: `auth`, `primary app`, `subpage`, and
  `admin`.
- For each variant, lock header density, leading action behavior, and auxiliary
  controls such as the theme toggle.
- Decide whether auth/setup should have zero chrome or intentionally branded
  chrome; the current “mostly empty top bar” sits in between.

## Remediation Priorities

1. Normalize CTA patterns.
   Pick one submit pattern per screen category and introduce a secondary modal
   action style.

2. Consolidate option-list and search-result primitives.
   This will reduce divergence fastest in the most interaction-heavy screens.

## Notes

- This audit is based on the current codebase and its route structure.
- The strongest parts of the design system are already centralized; this is a
  normalization job, not a redesign-from-scratch job.
- This audit now treats system-native text rendering as an acceptable product
  choice rather than a defect, unless the team later decides to bundle and lock
  a specific typeface.
- The previous iconography finding is now resolved by the shared SVG icon
  system.
- The previous theme-token finding is now resolved.
- The previous heading-scale finding is now resolved by the typography rework
  that standardized font sizes, simplified heading signatures, and introduced
  `listItemTitle` for row content.
- The next active priority is CTA consistency.
