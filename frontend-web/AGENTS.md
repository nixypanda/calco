# Frontend Web Agent Instructions

This directory contains the active frontend. Also read the repository root
`AGENTS.md` and `../docs/frontend.md` before changing frontend behavior.

## Shape

- Elm 0.19.1 `Browser.application`.
- Uses `mdgriffith/elm-ui`; shared UI primitives live in `src/Ui.elm`.
- Talks to the Rust backend through HTTP JSON under `/api`.
- Main areas:

```text
src/Api/
src/Data/
src/Lib/
src/Page/
src/View/
src/Main.elm
src/Ui.elm
tests/
```

## Architecture

- Page modules should follow TEA with `Model`, `Msg`, `init`, `update`, `view`,
  and `subscriptions`.
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
nix develop -c just frontend-web-line-length
nix develop -c just frontend-web-review
nix develop -c just frontend-web-test
nix develop -c just frontend-web-format
```

Direct commands:

```bash
cd frontend-web && elm-test
cd frontend-web && elm-review
cd frontend-web && elm-format --yes src tests
```

Build and run:

```bash
nix develop -c just frontend-web-build
nix develop -c just frontend-web-dev
```

## Gotchas

- **New files under `src/Data/` or `tests/Data/` need a `.gitignore` negation.**
  The root `.gitignore` ignores `data/` for the import pipeline, and macOS
  matches that case-insensitively, so `Data/` is caught too. `git status` stays
  silent and the file never lands in a commit — three test files sat untracked
  this way. Run `git status` after adding one.
