# Tools Agent Guardrails

Read the repository root `AGENTS.md` and the relevant docs before changing
anything in this directory.

## Boundaries

- Keep application business behavior in `../backend` or `../frontend-web`.
- Tools should support local operations, data conversion, or imports.
- Prefer existing CalCo APIs over direct database writes.
- Do not commit generated caches, raw personal exports, local scratch data, or
  private review artifacts.

## Where To Start

- `../docs/imports.md` explains the tools tree, the catalog data-sources
  pipeline, and the backend import API and normalized row contracts.
- `../docs/personal-data-import.md` explains the personal-data importer.

Use repository-level `just` checks when they apply, and the importer-specific
checks documented in `../docs/imports.md` when touching Python tooling.
