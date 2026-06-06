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

Food import tooling lives under `importers/`. Read `importers/AGENTS.md`,
`../docs/imports.md`, and `importers/README.md` before changing importer
behavior.

## Checks

Use repository-level `just` commands when they apply:

```bash
just test
just build
```

For importer-specific Python checks, run them from `tools/importers` as
documented in `importers/AGENTS.md`.

