# Data Sources Agent Guardrails

Read `../../../AGENTS.md` and `../../../docs/imports.md` before changing this
importer.

- This is the public catalog dataset pipeline for USDA, IFCT, INDB, and Open
  Food Facts.
- Keep converters focused on projecting source datasets into the current CalCo
  product and nutrient model.
- Use uppercase source codes such as `USDA`, `IFCT`, `INDB`, and `OFF` in
  normalized rows.
- Adding new product fields such as ingredients or allergens requires backend
  schema/domain work, not just converter flags.
- Prefer the backend import API over direct database writes.
- Do not commit downloaded source archives, generated processed data, or local
  caches.

Run the checks documented in `../../../docs/imports.md` before handing off
converter changes.
