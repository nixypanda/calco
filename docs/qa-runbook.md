# CalCo QA Runbook

## Purpose

Use this runbook to exercise CalCo end to end against the existing test database. Do not reset, truncate, reseed, or replace the database. The run creates uniquely named food, meal, log, and optional admin-user records so they cannot be confused with existing data.

Run the checklist in the in-app browser. Camera-based barcode scanning is out of scope; manual barcode lookup is covered.

Randomize the viewport before each numbered flow. Choose one of these three viewport presets and record the selected preset in the execution notes:

| Preset | Viewport |
| --- | --- |
| iPhone SE | 375 x 667 |
| iPad | 768 x 1024 |
| Desktop | 1440 x 900 |

Use an unbiased random choice for each flow rather than cycling through the presets in a fixed order. A complete run must exercise every preset at least once. If random selection has not chosen all three by the final flow, assign the missing preset to that flow. Repeat the highest-risk paths (diary, search, food logging, and destructive confirmation dialogs) at all three sizes before release sign-off.

## Environment

- PostgreSQL: existing CalCo test database from `docker-compose.yml`
- Backend: `http://localhost:3001`
- Frontend: use the active CalCo Vite URL; this run used `http://127.0.0.1:5174`
- Regular user: `me` / `mepass123`
- Admin user: `admin` / `adminpass123`

Start or verify the services without changing database contents:

```bash
docker compose ps
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-migrate
DATABASE_URL=postgres://calco:calco@localhost:5432/calco nix develop -c just backend-dev
API_TARGET=http://127.0.0.1:3001 nix develop -c npm --prefix frontend-web run dev -- --host 127.0.0.1 --port 5174
```

If port `1234` is occupied by another app, do not test that app by mistake. Confirm the page title and login branding both say `CalCo` before continuing.

## Test Data

Create one run ID at the start:

```text
QA-YYYYMMDD-<five random digits>
```

Use these values throughout the run:

| Record | Value |
| --- | --- |
| Custom food | `<run-id> Food Alpha` |
| Brand | `CalCo QA` |
| Food notes/log notes | `<run-id> breakfast log` |
| Meal | `<run-id> Meal Alpha` |
| Meal notes | `<run-id> meal notes` |
| Optional admin user | `qa_<run-id-lowercase-with-underscores>` |
| Invalid barcode | `999` plus ten random digits |

Custom food nutrition per 100 g:

| Nutrient | Amount |
| --- | ---: |
| Energy | 200 kcal |
| Protein | 10 g |
| Carbohydrates | 20 g |
| Fat | 8 g |

## Browser Checklist

Before starting each numbered section below:

1. Randomly select iPhone SE, iPad, or Desktop from the viewport table above.
2. Apply that viewport before navigating to the first page in the section.
3. Record the preset and dimensions with the section result.
4. Keep the selected viewport for that entire section so layout changes do not interrupt in-progress forms.
5. Reset or randomize the viewport again before the next numbered section.

### 1. Authentication and route protection

1. Open `/login` and submit an invalid password. Verify the error is visible and no authenticated page is shown.
2. Log in as `me`. Verify `/home` loads and the profile menu says the user is signed in as `me`.
3. Reload `/home` and verify the session survives.
4. Open `/admin` as `me`. Verify the admin page is denied or the user is redirected.
5. Log out. Verify protected routes return to `/login`.
6. Log in as `admin`. Verify `/admin` loads.

### 2. Diary and date navigation

1. Record the current day's totals and existing entries before creating data.
2. Use Previous Day and Next Day. Verify the heading, URL date, entries, goals, and totals all change together.
3. Return to the original date and verify no entries were changed by navigation.
4. Expand each meal's macro summary and verify it agrees with visible entries.
5. Check an empty meal slot. Verify it shows `No items` and `+ Add Food`.

### 3. Goals

1. Open `/settings/goals` and record the existing values.
2. Enter calories that do not equal `protein*4 + carbs*4 + fat*9` and save.
3. Verify the form rejects the values with a clear validation message.
4. Enter a valid set and save. Reload the page and verify persistence.
5. Restore the original goal values and save again.

### 4. Custom food lifecycle

1. Open `/foods/custom/new`.
2. Submit an empty form and verify required-field errors.
3. Create `<run-id> Food Alpha` using the nutrition values above.
4. Add a category and serving conversion, then verify both appear on the detail page.
5. Verify the food detail shows the expected brand, serving size, calories, and macros.
6. Edit the food name to `<run-id> Food Updated`, change one nutrient, and save.
7. Reload and verify the changes persisted.
8. Restore the original nutrient values if the food will be used for later total assertions.

### 5. Food search, completion, and history

1. From an empty Breakfast slot, open `+ Add Food`.
2. In All search, search for a known catalog food and verify results and category completion.
3. In Custom search, search for the run ID and verify only the generated food is returned.
4. Open the result and verify the date and `meal_slot=breakfast` context is preserved.
5. Log 100 g with notes `<run-id> breakfast log`.
6. Verify the diary adds exactly 200 kcal, 10 g protein, 20 g carbs, and 8 g fat.
7. Return to search, select History, and search for the run ID.
8. Verify the newly logged food is returned. Also verify it appears in recent items where that section is available.
9. Search a query with no matches and verify the empty state offers custom-food creation.

### 6. Manual barcode lookup

1. Select Barcode search.
2. Enter the generated invalid barcode and press Search.
3. Verify a single clear not-found state is shown and `Create Custom Food` is available.
4. Enter a known barcode from an existing catalog fixture and verify it opens the correct food detail.
5. Do not press Scan and do not grant camera permission in this run.

### 7. Food log lifecycle and snapshots

1. Open the generated diary entry.
2. Change its quantity from 100 g to 50 g, move it from Breakfast to Lunch, and update the notes.
3. Save and return to the diary.
4. Verify Breakfast loses the entry, Lunch gains it, and the run contribution becomes 100 kcal, 5 g protein, 10 g carbs, and 4 g fat.
5. Edit the source custom food's name or nutrients.
6. Verify the existing log still displays its original food snapshot and nutrition.
7. Delete the log and confirm deletion.
8. Verify the entry disappears and totals return exactly to their pre-run values.

### 8. Meal lifecycle

1. Open `/meals/new`.
2. Create `<run-id> Meal Alpha`, total quantity `100 g`, using 100 g of the generated food.
3. Verify the meal detail and nutrient preview both show 200 kcal, 10 g protein, 20 g carbs, and 8 g fat.
4. Edit the meal name to `<run-id> Meal Updated` and verify persistence.
5. From the diary/search flow, log the saved meal to a meal slot and verify all components are logged atomically.
6. Verify the resulting diary totals and component snapshots.
7. Delete any meal-created logs before deleting the meal.
8. Delete the meal and verify it disappears from `/meals`.

If step 5 has no visible action, record it as a blocking product defect. Do not bypass the missing UI by writing directly to the API during an end-to-end UI run.

### 9. Latest-slot repeat

1. On the previous day, log at least one uniquely tagged item to an otherwise identifiable meal slot.
2. Return to the current day with that slot empty.
3. Use the latest-slot action.
4. Verify all expected items are copied once with the correct quantities, units, notes, meal slot, and snapshots.
5. Repeat the action and verify duplicate behavior matches the product decision.
6. Delete all copied and source QA logs.

### 10. Admin flows

1. Log in as `admin` and verify the admin user list loads.
2. Open the existing `me` user and verify username, display name, status, creation time, reset-password form, and disable action are present.
3. Open Create User and verify empty and partial submissions show required-field errors.
4. For a full destructive regression, create the optional tagged user and verify it can log in.
5. Reset only that tagged user's password and verify old-password failure and new-password success.
6. Disable only that tagged user and verify login is rejected; re-enable it and verify login succeeds.

There is currently no user-delete flow. A created admin QA user cannot be fully cleaned up through the app; leave it disabled and record its username. Do not disable, reset, or otherwise mutate `me` or `admin` merely to exercise the controls.

### 11. Responsive and failure states

1. Review the execution record and verify iPhone SE, iPad, and Desktop were each selected at least once by the randomized flow assignments.
2. Repeat login, diary, search, food form, meal form, and confirmation-modal checks at any preset they did not already run against.
3. Run diary, search, food logging, and destructive confirmation dialogs at all three viewport presets before release sign-off.
4. Verify controls do not overlap, text does not clip, modals remain reachable, and dropdowns remain usable.
5. Verify changing to a new randomized viewport between flows does not leave navigation, menus, or overlays in a broken state.
6. With the backend temporarily unavailable, submit login/search once and verify the network error is understandable and recoverable after the backend returns.
7. Check the browser console for uncaught errors after each major flow.

## Cleanup

Clean up in dependency order:

1. Delete every log containing the run ID, including latest-slot copies and meal component logs.
2. Delete the generated meal.
3. Delete the generated custom food.
4. Restore the original goals.
5. Disable the optional admin QA user because user deletion is unavailable.
6. Search All, History, and Custom for the run ID. Verify no generated food, meal, or log remains; history may retain a deliberate audit/search-history record if that is product behavior.
7. Confirm diary totals match the values recorded before the run.

Never delete or edit pre-existing foods, logs, meals, or users during cleanup.

## Bug Report Template

```text
ID:
Severity: blocker | high | medium | low
Flow:
Environment and URL:
Viewport preset and dimensions:
Test user:
Run ID:
Preconditions:
Steps:
Expected:
Actual:
Reproducibility:
Console/network evidence:
Screenshot or recording:
Cleanup status:
```

## Execution Record: 2026-07-10

Run ID: `QA-20260710-36970`

Passed in the in-app browser:

- Regular-user and admin login
- Diary load and nutrition totals
- Goals formula validation
- Custom food create, detail, search, and delete
- Custom and History search scopes
- Manual invalid-barcode lookup
- Product log create, edit quantity, move Breakfast to Lunch, update notes, and delete
- Diary total recalculation after create, edit, and delete
- Meal create, nutrient preview, edit, list, and delete
- Admin list, existing-user detail, and create-user validation
- Cleanup of the generated log, meal, and custom food

Defects and gaps found:

1. **Medium: duplicate barcode not-found messaging.** A single lookup displayed both `No food matched that barcode.` and `No food found for that barcode.` before the create-food action. The empty state should present one message.
2. **High: saved meals cannot be logged through the visible UI.** Meal create, detail, edit, list, and delete work, but neither the meal detail nor the diary/search flow exposes a `Log Meal` action. This blocks the advertised meal-logging flow and prevents UI coverage of atomic component logging.
3. **Low/Performance risk: My Foods renders a very large unfiltered list.** The existing test account produced a page with hundreds of interactive food rows and no list-level search or pagination. Validate responsiveness and keyboard usability with production-sized datasets.

Environment observations that are not product defects:

- Port `1234` was serving another local app, so CalCo was run on `5174`.
- A stale login page reported `Network error` while both CalCo dev servers were stopped. Login succeeded after the services were restarted with the API proxy pointed to `127.0.0.1:3001`.
