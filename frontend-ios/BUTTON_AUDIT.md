# Native button audit

Source audit of `App/`, `Components/`, and all feature views, November 23, 2026.
This is not a claim of visual acceptance on every device.

## Conventions

- Screen-wide commit actions use a prominent button. Bottom action bars expand
  the **label inside the Button**, not just the surrounding container.
- Bottom primary actions stay outside scrolling forms and above the keyboard.
  Persistent deletion belongs in a separate final form section, not beside Save.
- Destructive actions retain `.destructive`, use red, and confirm persistent
  deletion. Removing an unsaved form row is immediate and does not need a dialog.
- Icon-only removal actions have a descriptive accessibility label and at least
  a 44-point target.
- Navigation, menus, list rows, and contextual actions retain native styling;
  they should not all become prominent/full-width buttons.
- Custom-food and meal editors are pushed pages: native Back when clean,
  guarded Back when dirty/busy, and trailing Save. Ingredient selection is a
  child page, not an expanding search form inside the recipe.
- Temporary logging tasks use sheets with leading Cancel and one bottom Log
  action. Date selection and repeat review retain Cancel/Done or Cancel/Log.
- Root tabs have no Back/Close. API Keys and Nutrition are pushed pages.
- Do not duplicate the same commit action in a toolbar and bottom bar.

## Inventory and disposition

| Location | Actions and placement | Disposition |
| --- | --- | --- |
| Sign in | Submit in form; keyboard submit | Submit now prominent, full-width, 44-point label; keyboard action remains compact. |
| Session/admin/configuration states | Return to sign in / retry in empty-state content | Keep prominent recovery action near its explanation. |
| App shell | Tabs, back/close, pending-submission banner | Keep native navigation; banner Discard now has destructive role. |
| Diary | Date arrows/calendar, settings/refresh/sign out; slot add, latest-log and log rows | Keep navigation in toolbar/header and contextual actions in their owning section. Latest-log review uses Cancel/Log toolbar actions. |
| Diary log editor | Save in fixed bottom bar; Delete in final form section | Save is the sole full-width primary action and remains gated for unchanged/reverted/invalid forms. Delete stays red and confirmed, away from the primary commit. |
| Search | Clear, filters, barcode lookup, result rows, quick-add and batch review | Keep contextual controls with results; row navigation stays plain and quick-add stays distinct. Recovery buttons remain with errors. |
| Food logging | Task sheet with Cancel and one bottom Log action | Search remains underneath with its query and context intact. Busy submissions prevent dismissal. Retain separate pending recovery actions and existing retry semantics. |
| Library | Add menu, food rows, trailing detail Edit; final-section Delete | Native Back and one trailing Edit action. Persistent deletion remains separate and confirmed. |
| Custom-food editor | Back/Save page; add/remove servings and nutrients inline | Native Back when clean and guarded Back when dirty/busy. Save returns to the owning page; editing refreshes the retained detail. |
| Ad-hoc log | Cancel/Log toolbar; save-food/retry actions in related sections | Keep one commit location, with explicit retry next to retained intent/error. |
| Meals list/flow | Add/close/back toolbar; list rows and quick logging | Keep native navigation and context-specific logging. |
| Meal editor | Back/Save page; ingredient picker child page | Creation and editing use the same pushed-page structure. Row removal stays inline and red. |
| Meal detail | Trailing Edit, final-section Delete, bottom Log entry | Logging opens a separate portion/preview task sheet with Cancel and one Log commit. |
| Nutrition details | Pushed report page with native Back | Keep recovery local; disclosure controls remain native, not prominent. |
| AI assistant | Close, overflow Start Over, Send composer, draft review actions | Start Over is secondary and confirmed; Accept remains prominent and Ask for changes secondary. |
| Diary settings | Root tab; section-local saves; pushed API Keys | No root Back button. Keep saves beside independently persisted sections and preserve their existing validation. |
| API keys | Pushed list with native Back and Add; create sheet with Cancel | Create has one bottom commit. Secret completion says Done, not Back; one-time-secret handling is unchanged. |
| Date picker | Cancel/Done toolbar | Keep native confirmation placement. |

## Remaining improvements

- Custom-food and meal editors still allow unchanged saves. Unify these with the
  log editor in a follow-up using reversible baselines (custom-food `isDirty`
  currently records interaction, not equality); retain valid creation and
  reviewed-AI-draft submission paths.
- Food-detail pending-recovery pairs and the assistant composer remain candidates
  for narrow-width/large-text visual QA. Do not move recovery into the primary
  commit or change retry semantics as a styling change.
- The unused meal-detail `actionBar` is not the normal detail layout. A future
  cleanup can remove it separately; this audit does not switch normal detail
  actions to a second location.

Regression coverage: log save gating, field edits/reverts, invalid input,
failure/retry, and existing navigation tests. The mini UI reachability test also
checks the single full-width Save and unchanged/edited/reverted Save states; it needs
the isolated mock-backed UI runner.
