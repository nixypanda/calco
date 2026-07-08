# Tools Agent Guardrails

Read the repository root `AGENTS.md` and the relevant README before changing
anything in this directory.

## Boundaries

- Keep application business behavior in `../backend` or `../frontend-web`.
- Tools should support local operations, data conversion, or imports.
- Prefer existing CalCo APIs over direct database writes.
- Do not commit generated caches, raw personal exports, local scratch data, or
  private review artifacts.

## Where To Start

- `README.md` explains the tools tree.
- `importers/README.md` explains catalog and personal-data importers.
- `../docs/imports.md` explains the backend import API and normalized row
  contracts.

Use repository-level `just` checks when they apply, and importer-specific
checks from each importer README when touching Python tooling.
