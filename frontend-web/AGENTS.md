# Frontend Web Agent Instructions

This directory contains the active frontend. Also read the repository root
`AGENTS.md` and `../docs/frontend.md` before changing frontend behavior.

## Shape

- Elm 0.19.1 `Browser.application`.
- Uses `mdgriffith/elm-ui`; shared UI primitives live in the `src/Ui/` module
  family.
- Talks to the Rust backend through HTTP JSON under `/api`.
- Main areas:

```text
src/Api/
src/Component/
src/Data/
src/Lib/
src/Page/
src/View/
src/Main.elm
tests/
```

## Architecture

- Page modules should follow TEA with `Model`, `Msg`, `init`, `update`, `view`,
  and `subscriptions`.
- Reusable nested TEA modules and stateful forms live in `src/Component/`;
  modules shared across page categories live at the `Component` root, while
  category-specific components remain nested.
- `Main.elm` owns global routing/session/bootstrap state and wraps page
  messages with `PageMsg`.
- Pages that need global effects should return an `OutMsg` such as
  `SessionExpired` or `NavigateTo Route`.
- Keep URL-sourced state in routes/query params when it is navigation-critical.
- Route access is enforced through `src/Access.elm` and coordinated from
  `src/Main.elm`.

## State Modeling

- Prefer page-specific union types for meaningful loading, loaded, failed,
  submitting, and deleting states.
- Avoid loaded models made from independent `Maybe` fields when those fields
  are logically required together.
- `Loadable` is fine for small isolated values where all variants are valid.

## Runtime

- `index.html` loads the compiled Elm bundle from `dist/main.js`.
- Vite serves the frontend and proxies `/api/*` to the backend during local development.
- Defaults:

```text
frontend-web: http://localhost:1234
backend API:  http://localhost:3001
```

## Quality Gates

Before committing frontend changes, run these from the repository root:

```bash
just check-frontend-line-length
just check-frontend-review
just test-frontend
just format-frontend
```

Direct commands:

```bash
cd frontend-web && elm-test
cd frontend-web && elm-review
cd frontend-web && elm-format --yes src tests
```

Build and run:

```bash
just build-frontend
just dev-frontend
```

## Gotchas

- **New files under `src/Data/` or `tests/Data/` need a `.gitignore` negation.**
  The root `.gitignore` ignores `data/` for the import pipeline, and macOS
  matches that case-insensitively, so `Data/` is caught too. `git status` stays
  silent and the file never lands in a commit — three test files sat untracked
  this way. Run `git status` after adding one.
