# Known Issues

Items below are acknowledged but deprioritized given the current scale (tens of users, trusted homelab deployment). Revisit if user count grows or the app is exposed beyond a small known group.

## Concurrency

### TOCTOU on admin bootstrap
`create_bootstrap_admin` (backend/src/application/auth.rs:75) checks `admin_exists()` and then inserts. Two concurrent requests can both pass the check, producing multiple admins. No DB constraint enforces a single admin.

Mitigation if ever needed: add `CREATE UNIQUE INDEX ON identities ((role)) WHERE role = 'admin'` and map the unique-violation to `AdminAlreadyExists`.

### TOCTOU on username uniqueness
`admin_create_user` (backend/src/application/auth.rs:222) checks the username, then inserts. The `identities.username` unique constraint catches the race, but the violation surfaces as a `Database(...)` 500 instead of a clean `UsernameTaken` 409.

Mitigation if ever needed: catch the unique-violation and map to `UsernameTaken`.

### Non-atomic reads of food logs
`PostgresFoodLogRepository::find_by_id` / `find_by_user_and_range` (backend/src/infrastructure/postgres/food_log.rs:124, 146) fetch the log header and the nutrient snapshots in separate non-transactional statements. A concurrent `update_food_log` between the two reads can return a log header from one version with snapshots from another.

Mitigation if ever needed: single join, or wrap reads in a `REPEATABLE READ` transaction.

## Import pipeline

### Source fields dropped during conversion
Each converter projects the source dataset down to a narrow set of fields (`source`, `source_id`, `name`, `brand`, `category`, `serving_size_g`, plus mapped nutrients). Anything else in the source row is discarded, and `staging_*.raw_payload` is hardcoded to `None` in `interfaces/http/import.rs`, so there is no fallback either.

Examples currently dropped:
- **USDA**: `gtinUpc` (barcode for branded items), `scientificName`, `ndbNumber`, `dataType`, `publicationDate`, `ingredients`, `dataSource`.
- **OFF**: `ingredients_text`, `allergens`, `additives_tags`, `nova_group`, `nutriscore_grade`, `ecoscore_grade`, `labels`, `packaging`, image URLs, `*_serving` nutrient variants.
- **IFCT**: any column not listed in `nutrient_mapping/ifct2017_codes.json` (scientific name, edible portion, refuse, water content, regional names).

Recovery is by re-running the converters against the raw archives in `data/raw/`, so no data is permanently lost — but adding any of these to the product model is a deliberate schema + domain change, not a "flip a flag" operation. Each field needs: a column on `products` (or a side table), a domain field, a converter mapping, a `FoodRow` field on the HTTP boundary, and a commit-SQL projection.

Mitigation if ever needed: pick the specific fields worth surfacing (likely `ingredients_text` / `allergens` for OFF), then thread them through domain → staging → products in one go.
