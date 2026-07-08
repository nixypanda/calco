# CalCo Tools

Operational tooling for CalCo lives here. These tools support local workflows
around data conversion and imports; they should not contain core application
behavior.

## Directory Map

| Path | Purpose |
| --- | --- |
| `importers/data-sources/` | Converts public food datasets such as USDA, IFCT, INDB, and Open Food Facts into normalized catalog import rows. |
| `importers/personal-data/` | Cleans and imports private user exports, currently MyFitnessPal data, through user-facing APIs. |

The backend import API and normalized row shapes are documented in
`../docs/imports.md`.

## Working Rules

- Keep tools CLI-oriented and reproducible.
- Use existing CalCo APIs where possible.
- Keep backend schema and business rules in `../backend`.
- Keep frontend behavior in `../frontend-web`.
- Do not commit raw personal exports, downloaded source archives, generated
  caches, or local scratch outputs.

## Common Commands

Run repository checks from the repo root when a tooling change could affect the
application:

```bash
nix develop -c just test
nix develop -c just build
```

Each importer has its own README with Python-specific commands.

## Data Privacy

The personal-data importer can contain private diary history and food names.
Prefer aggregate counts and schema-level examples in docs. Remove one-off
analysis and generated reports when they are no longer part of the active
workflow.
