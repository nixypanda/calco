# Tools Agent Instructions

This directory contains operational tooling for CalCo. Also read the repository
root `AGENTS.md` and the relevant docs in `../docs/` before changing tools.

## Scope

- Tooling should support local operations, data conversion, imports, or
  verification workflows.
- Keep application business behavior in `../backend` or `../frontend-web`;
  tools should call existing APIs or produce normalized inputs unless a schema
  or domain change is explicitly required.
- Avoid committing generated caches or local data artifacts. `.ruff_cache/` is
  not source.

## Import Tools

Import tooling lives under `importers/` in two subdirectories:

- **`importers/data-sources/`** — catalog dataset pipeline (USDA, IFCT, INDB,
  OFF). Produces normalized JSONL for the backend import API.
- **`importers/personal-data/`** — user personal data import from other apps
  (MyFitnessPal, etc.). Creates private foods and diary entries via
  user-facing APIs.

Read `importers/data-sources/AGENTS.md` or `importers/personal-data/AGENTS.md`
and `../docs/imports.md` before changing import behavior.

## Checks

Use repository-level `just` commands when they apply:

```bash
just test
just build
```

For importer-specific Python checks, see the individual `AGENTS.md` files in
each subdirectory under `importers/`.

