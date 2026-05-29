# Food Tracker Feature Stories

## Summary

This document captures product features as user stories before mapping them into granular implementation features and API calls.

The current implementation focus is the MVP:

```text
Search/select food -> log quantity -> snapshot nutrients -> review daily totals
```

## MVP User Stories

As a user, I want to search for a food by name, brand, category, or barcode so that I can quickly find something I ate.

As a user, I want to view a food's nutrition per 100g so that I can decide whether it matches what I consumed.

As a user, I want to view a food's serving options so that I can log common portions like one packet, one scoop, or one cup.

As a user, I want to create a custom food with calories and macros so that I can track foods that are not in the catalog.

As a user, I want to edit my custom foods so that I can correct nutrition values or serving sizes.

As a user, I want to delete my custom foods so that I can remove foods I no longer use.

As a user, I want to log a food with quantity, unit, time, and meal slot so that my daily intake is recorded accurately.

As a user, I want logged nutrition to be snapshotted at the time of logging so that my history does not change when food data is edited later.

As a user, I want to see all foods I logged today so that I can review my current day.

As a user, I want to see today's calorie and macro totals so that I know how much I have consumed.

As a user, I want to edit a food log so that I can fix mistakes in quantity, time, meal slot, or selected food.

As a user, I want to delete a food log so that I can remove accidental entries.

As a user, I want to view logs for a previous day so that I can review what I ate historically.

As a user, I want to view nutrient totals for a selected day so that I can compare daily intake over time.

As a user, I want to view nutrition totals across a date range so that I can understand trends.

As a user, I want the app to work well on my phone as an installable PWA so that I can log food quickly throughout the day.

As a user, I want a simple login/session so that my food logs and custom foods are private to me.

## Next User Stories

As a user, I want to create reusable meals or recipes from foods so that I can log common combinations faster.

As a user, I want to add multiple components to a meal with quantities so that the meal's nutrition reflects the actual recipe.

As a user, I want to log a saved meal so that I do not have to log every ingredient separately.

As a user, I want meal nutrition to be calculated from its components so that totals are accurate.

As a user, I want the system to prevent recursive meals so that meal nutrition calculations cannot break.

As an admin, I want to create an import job so that external food datasets can be loaded safely.

As an admin, I want to upload normalized food and nutrient data so that I can populate the catalog without direct database writes.

As an admin, I want import rows to be validated before commit so that bad external data does not corrupt the catalog.

As an admin, I want to see import errors by row so that I can fix source data or mappings.

As an admin, I want to reimport a dataset so that existing catalog foods can be updated by source id.

As an admin, I want Open Food Facts data converted into the generic import format so that packaged foods and barcodes are available.

As an admin, I want USDA data converted into the generic import format so that base ingredients are available.

## Later User Stories

As a user, I want to set calorie and macro goals so that I can compare intake against targets.

As a user, I want to track micronutrients so that I can understand vitamins and minerals in my diet.

As a user, I want to scan a barcode with my phone camera so that I can find packaged foods faster.

As a user, I want recent foods and today's logs cached offline so that brief network loss does not stop logging.

As a user, I want charts for calories and macros over time so that I can see trends.

As a user, I want to correct imported food data safely so that catalog quality improves without changing my historical logs.

As a user, I want to export my logs and custom foods so that I can back up or analyze my data elsewhere.

As an admin, I want backup and restore tooling so that user-entered data is protected.

As a household user, I want multiple user accounts so that each person has separate logs and custom foods.

## API Mapping Notes

These notes capture endpoint choices surfaced during feature mapping.

### Consolidated Endpoints

- Food detail uses `GET /foods/{id}` and includes product nutrients and servings. Do not add separate public `GET /foods/{id}/nutrients` or `GET /foods/{id}/servings` endpoints unless partial loading becomes necessary.
- Log history uses `GET /logs?from=YYYY-MM-DD&to=YYYY-MM-DD`. Use the same date for `from` and `to` for a single-day view. Do not add a separate `GET /logs/day/{date}` endpoint.
- Nutrition summaries use `GET /summary?from=YYYY-MM-DD&to=YYYY-MM-DD&codes=...`. Use the same date for `from` and `to` for daily totals. Omit `codes` to return all tracked nutrients.

### Identified API Gaps

- Add `GET /units` so custom food forms, serving forms, and log quantity controls can use canonical units.
- Add admin-only catalog correction APIs before direct edits to imported/global foods are supported.
- Add export job APIs when async exports are implemented: `POST /exports`, `GET /exports/{id}`, and `GET /exports/{id}/download`.
- Use the username/password auth flow from `auth_design.md`; OAuth/OIDC/Tailscale auth is out of scope.
