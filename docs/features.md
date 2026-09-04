# Food Tracker Feature Stories

## Summary

This document captures product features as user stories before mapping them into
granular implementation features and API calls.

Current implementation covers the core food diary plus configurable meal slots,
meals/recipes, repeat and recent-item logging, admin import staging/commit APIs,
and Python dataset import tooling:

```text
Search/select food -> log quantity -> snapshot nutrients -> review daily totals
```

The frontend currently implements auth, admin user management, diary, goal
settings, food search/detail, manual and camera-based barcode lookup, custom
food create/edit/show, log detail/edit, meals, and responsive layouts. The
product goal is a simple food tracker, not an analytics or trend platform.

## MVP User Stories

- [x] As a user, I want to search for a food by name, brand, category, or
      barcode so that I can quickly find something I ate.
- [x] As a user, I want to view a food's nutrition per 100g so that I can decide
      whether it matches what I consumed.
- [x] As a user, I want to view a food's serving options so that I can log
      common portions like one packet, one scoop, or one cup.
- [x] As a user, I want to create a custom food with calories and macros so that
      I can track foods that are not in the catalog.
- [x] As a user, I want to edit my custom foods so that I can correct nutrition
      values or serving sizes.
- [x] As a user, I want to delete my custom foods so that I can remove foods I
      no longer use.
- [x] As a user, I want to log a food with quantity, unit, time, and meal slot
      so that my daily intake is recorded accurately.
- [x] As a user, I want logged nutrition to be snapshotted at the time of
      logging so that my history does not change when food data is edited later.
- [x] As a user, I want to see all foods I logged today so that I can review my
      current day.
- [x] As a user, I want to see today's calorie and macro totals so that I know
      how much I have consumed.
- [x] As a user, I want to edit a food log so that I can fix mistakes in
      quantity, unit, meal slot, or notes.
- [x] As a user, I want to delete a food log so that I can remove accidental
      entries.
- [x] As a user, I want to view logs for a previous day so that I can review
      what I ate historically.
- [x] As a user, I want to view nutrient totals for a selected day so that I can
      compare daily intake over time.
- [x] As a user, I want to set calorie and macro goals so that I can compare
      intake against targets.
- [x] As a user, I want the app to work well on my phone so that I can log food
      quickly throughout the day.
- [x] As a user, I want a simple login/session so that my food logs and custom
      foods are private to me.

## Implemented Beyond The Initial MVP

- [x] As a user, I want to create reusable meals or recipes from foods so that I
      can log common combinations faster.
- [x] As a user, I want to add multiple components to a meal with quantities so
      that the meal's nutrition reflects the actual recipe.
- [x] As a user, I want to log a saved meal so that I do not have to log every
      ingredient separately.
- [x] As a user, I want meal nutrition to be calculated from its components so
      that totals are accurate.
- [x] As a user, I want the system to prevent recursive meals so that meal
      nutrition calculations cannot break. Current implementation prevents this
      by supporting product-only meal components.
- [x] As an admin, I want to create an import job so that external food datasets
      can be loaded safely.
- [x] As an admin, I want to upload normalized food and nutrient data so that I
      can populate the catalog without direct database writes.
- [x] As an admin, I want to upload normalized serving data so that imported
      products can include common portions.
- [x] As an admin, I want import rows to be validated before commit so that bad
      external data does not corrupt the catalog.
- [x] As an admin, I want to see import errors by row so that I can fix source
      data or mappings.
- [x] As an admin, I want to reimport a dataset so that existing catalog foods
      can be updated by source id.
- [x] As an admin, I want Open Food Facts data converted into the generic import
      format so that packaged foods and barcodes are available.
- [x] As an admin, I want USDA data converted into the generic import format so
      that base ingredients are available.
- [x] As an admin, I want IFCT data converted into the generic import format so
      that Indian food composition data is available.
- [x] As an admin, I want INDB data converted into the generic import format so
      that Indian recipe composition data is available.
- [x] As an admin, I want products from different data sources matched by name
      similarity before import so that the same food is not duplicated in the
      catalog.
- [x] As an admin, I want barcode-based dedup between sources so that packaged
      foods from OFF are merged with other sources where they share a barcode.
- [x] As an admin, I want macro consistency checks on matched products so that
      false matches are surfaced before they reach the catalog.
- [x] As an admin, I want a configurable source preference order so that
      higher-quality sources override lower-quality ones during merges.
- [x] As a user, I want to copy the most recent non-empty log set for a meal
      slot into today so that I can repeat common breakfasts, lunches, and
      dinners even when I skipped logging for a few days. Implemented with
      `GET /logs/latest-slots` plus `POST /logs/batch`, surfaced as `Log latest`
      actions on empty diary meal slots.
- [x] As a user, I want repeated meal-slot logging to ignore very old history
      so that the app does not unexpectedly copy stale eating patterns.
      Implemented with a bounded lookback window; the frontend requests 30 days
      and the backend validates 1-90 days.
- [x] As a user, I want to choose which meal slots appear in my diary so that
      the diary matches how I organize my day. Preferences are saved per user
      and editable from diary settings.

## Next User Stories

- [ ] As a user, I want to change my own password so that I do not need an admin
      reset for routine password changes.

### Food Capture And Assistant Todo

- [ ] Add image support to the food assistant so that users can provide food or
      nutrition-label photos as context when drafting a custom food. Image input
      must remain review-before-write and must not create catalog data by itself.
- [ ] Remove the portion section from the create-custom-food flow. Custom foods
      should initially be created from their per-100 g nutrition data without
      requiring the user to define an additional portion; serving support for
      catalog foods and food logging remains unchanged.
- [ ] When a barcode is not present in the local catalog, look it up in Open Food
      Facts (OFF). If OFF has a match, pull its product and nutrition data into
      CalCo and let the user continue with that food instead of entering it
      manually.
- [ ] When a barcode is absent from both the local catalog and OFF, let the user
      photograph the product's nutrition table. Use the image to prepare a
      custom-food draft, require the user to review and correct the extracted
      values, and create the food in the database only after explicit
      confirmation.

## Quality Of Life Backlog

These are workflow-speed improvements rather than new core nutrition
capabilities. They are grouped by theme so they can be ranked later.

### Repeat Behavior And Faster Logging

- [x] As a user, I want to see recent foods and recent meals first when adding
      to a meal slot so that I can log repeat items before searching the broader
      catalog. The search page shows recent items before a query is active, then
      replaces that list with search loading, errors, empty states, or results
      once the user searches. Recent items are ranked by time-decayed usage
      frequency, scored against the requested day, so habits the user has
      dropped sink on their own.
- [x] As a user, I want foods and meals to remember my last-used quantity and
      unit so that repeat logging defaults to how I actually consume them. The
      log form prefills the latest logged quantity and unit, and each recent row
      offers up to five quick-add quantity chips ranked the same time-decayed
      way.
- [ ] As a user, I want to duplicate an existing log to another meal slot or
      another day so that fixing or repeating entries is faster than re-entering
      them.

### Search And Selection

- [ ] As a user, I want search results to rank foods I have used before ahead of
      equally relevant unfamiliar foods so that logging gets faster over time.
- [ ] As a user, I want search results from my history or recents to appear
      before the full catalog so that I can pick familiar items faster.
- [ ] As a user, I want exact barcode matches, exact name matches, and recent
      matches to be visually surfaced before fuzzy matches so that search intent
      is clearer.
- [ ] As a user, I want foods previously used in the current meal slot to be
      ranked higher so that breakfast-like items surface first in breakfast, and
      similarly for other slots.
- [ ] As a user, I want a unified add flow that can surface both foods and saved
      meals so that I do not have to decide which area to search first.

### Barcode And Capture

- [x] As a user, I want to scan a barcode with my phone camera so that I can
      find packaged foods faster. The responsive search page uses the device
      camera to scan EAN and UPC barcodes, confirms a detection before accepting
      it, and opens the matching food.
- [x] As a user, I want to enter a barcode manually when camera scanning is not
      practical so that barcode lookup still works on desktop or with poor
      camera conditions. Barcode search accepts manual input and opens an exact
      catalog match.
- [x] As a user, I want the app to take me directly into create or import flows
      when a barcode is not found so that missing packaged foods are quick to
      add. A failed lookup offers a direct action to the custom-food creation
      form. Live OFF lookup and nutrition-table photo drafting are still planned
      in **Food Capture And Assistant Todo**.

### Editing And Diary Cleanup

- [ ] As a user, I want to move an existing log to a different day so that I can
      correct late-night or backfilled entries without deleting and recreating
      them.
- [ ] As a user, I want faster inline edits for quantity, unit, or meal slot
      from the diary view so that minor corrections do not require opening the
      full log detail.

## Later User Stories

- [x] As a user, I want to track micronutrients so that I can understand
      vitamins and minerals in my diet. Nutrients are modeled generically and
      logged/summarized from snapshots; a dedicated micronutrient dashboard is
      still not present.
- [ ] As a user, I want recent foods and today's logs cached offline so that
      brief network loss does not stop logging.
- [ ] As a user, I want to export my logs and custom foods so that I can back up
      or analyze my data elsewhere.
- [ ] As an admin, I want backup and restore tooling so that user-entered data
      is protected.
- [x] As a household user, I want multiple user accounts so that each person has
      separate logs and custom foods.
