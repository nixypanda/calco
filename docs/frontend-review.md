# Frontend Codebase Review

Mode: code reading only; browser control was unavailable, so the required six
visual captures were not run.

## Verification

The following gates passed:

- 100-column check
- `elm-review`
- 803 Elm tests
- `elm-format --validate src tests`
- Worktree left clean

## Blocking

No blocking findings remain.

## Material

1. Modals are visual overlays rather than accessible dialogs. There is no
   dialog or `aria-modal` semantic, focus containment, initial focus, focus
   restoration, or Escape handling. The backdrop is an unlabeled full-screen
   button. Destructive confirmations therefore remain reachable to pointer
   users but are unreliable for keyboard and screen-reader users.

   Files: `frontend-web/src/Ui/Feedback.elm:71` and
   `frontend-web/src/View/DeleteModal.elm:41`.

   Repair with `$elmcraft harden frontend-web/src/Ui/Feedback.elm`.

2. Four imports contradict the documented dependency graph. `Data.Auth`
   depends on the transport-layer `Api.Client.ApiError`, while three `View`
   modules depend directly on API response types. This prevents the domain and
   presentation layers from remaining transport-independent.

   Files: `frontend-web/src/Data/Auth.elm:20`,
   `frontend-web/src/View/Search.elm:6`,
   `frontend-web/src/View/Product.elm:7`, and
   `frontend-web/src/View/QuantityInput.elm:3`.

   Repair with `$elmcraft restructure frontend-boundaries`.

## Resolved

- Blocking 1: shared-palette accessibility contrast.
- Material 2: 44x44 minimum touch targets.
- Material 3: UI-law styling leakage. Scrim and goal colors are semantic theme
  slots; generic color operations live in `Ui.Color`; spacing and typography
  use shared tokens; and the diary row uses the shared `minWidthZero` helper.
- Material 4: actionable generic transport errors.

## Minor

1. Nutrition columns are correctly right-aligned, but stacked numeric values
   do not use tabular figures or decimal alignment. This makes comparison less
   stable in a number-heavy diary.

   File: `frontend-web/src/View/Nutrients.elm:458`.

   Repair with `$elmcraft polish frontend-web/src/View/Nutrients.elm`.

2. The frontend documentation repeatedly identifies `src/Ui.elm` as the
   shared primitive module, but that file no longer exists; the implementation
   is the `Ui/` module family. This can misdirect future changes.

   Files: `frontend-web/AGENTS.md:9` and `docs/frontend.md:21`.

   Repair with `$elmcraft document`.

## Clean

The architecture is otherwise disciplined:

- Page models generally use explicit loading, loaded, failed, submitting, and
  deleting unions.
- Search, autocomplete, store hydration, and other race-prone requests carry
  tickets or request tokens and reject stale completions.
- HTTP execution and global effects remain page/application-owned.
- Main content, navigation, and heading landmarks are present.
- Reduced-motion handling covers transitions, modal animation, and skeleton
  shimmer.
- Loading states usually preserve layout with purpose-built skeletons.
- Responsive workspace pane visibility is centralized.
- The test suite is broad and all 803 tests pass.
