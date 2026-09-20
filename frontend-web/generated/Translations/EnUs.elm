module Translations.EnUs exposing (enUsTranslations)

import Translations.Ids exposing (TranslationId(..))


enUsTranslations : TranslationId -> String
enUsTranslations tid =
    case tid of
        TidApiErrorBadBody ->
            "The server returned an unexpected response. Refresh the page and try again."

        TidApiErrorBadUrl ->
            "Could not connect to the server. Refresh the page and try again."

        TidApiErrorNetwork ->
            "Could not reach the server. Check your connection and try again."

        TidApiErrorRateLimited ->
            "Too many requests. Please wait before trying again."

        TidApiErrorRateLimitedSeconds hole0 ->
            "Too many requests. Try again in " ++ hole0 ++ " seconds."

        TidApiErrorServer ->
            "The server could not complete the request. Try again."

        TidApiErrorTimeout ->
            "The server took too long to respond. Try again."

        TidCalendarMonthApril ->
            "April"

        TidCalendarMonthAugust ->
            "August"

        TidCalendarMonthDecember ->
            "December"

        TidCalendarMonthFebruary ->
            "February"

        TidCalendarMonthJanuary ->
            "January"

        TidCalendarMonthJuly ->
            "July"

        TidCalendarMonthJune ->
            "June"

        TidCalendarMonthMarch ->
            "March"

        TidCalendarMonthMay ->
            "May"

        TidCalendarMonthNovember ->
            "November"

        TidCalendarMonthOctober ->
            "October"

        TidCalendarMonthSeptember ->
            "September"

        TidCalendarMonthYear hole0 hole1 ->
            hole0 ++ " " ++ hole1

        TidCommonCancel ->
            "Cancel"

        TidCommonClose ->
            "Close"

        TidCommonCreated ->
            "Created"

        TidCommonCreating ->
            "Creating..."

        TidCommonDisplayName ->
            "Display Name"

        TidCommonLoading ->
            "Loading..."

        TidCommonNewVersionAvailable ->
            "New version available"

        TidCommonPassword ->
            "Password"

        TidCommonProfile ->
            "Profile"

        TidCommonRouteNotMigrated ->
            "This route is not migrated yet."

        TidCommonSave ->
            "Save"

        TidCommonSaving ->
            "Saving..."

        TidCommonSignedIn ->
            "Signed in"

        TidCommonSignedInAs hole0 ->
            "Signed in as " ++ hole0

        TidCommonStatus ->
            "Status"

        TidCommonTapToRefresh ->
            "Tap to refresh"

        TidCommonUseDarkTheme ->
            "Use dark theme"

        TidCommonUsername ->
            "Username"

        TidCommonUsernameRequired ->
            "Username is required"

        TidCustomFoodConfirmDelete ->
            "Confirm Delete"

        TidCustomFoodDelete ->
            "Delete Food"

        TidCustomFoodDeleteConfirmDescription ->
            "This will permanently remove the custom food."

        TidCustomFoodDeleteConfirmTitle ->
            "Delete food?"

        TidCustomFoodDeleting ->
            "Deleting..."

        TidCustomFoodDuplicateServingUnit hole0 ->
            "Each serving must use a unique unit (duplicate: " ++ hole0 ++ ")"

        TidCustomFoodEnterManually ->
            "Enter manually"

        TidCustomFoodInvalidDefaultPortion ->
            "Default portion must be grams or use a configured serving unit"

        TidCustomFoodInvalidNutrientAmount hole0 ->
            "Nutrient amount must be a non-negative number (got: " ++ hole0 ++ ")"

        TidCustomFoodInvalidServingGrams hole0 ->
            "Grams per serving unit must be a positive number (got: " ++ hole0 ++ ")"

        TidCustomFoodListEmpty ->
            "No items yet."

        TidCustomFoodNameRequired ->
            "Name is required"

        TidCustomFoodSave ->
            "Save Food"

        TidDateMonthApr ->
            "Apr"

        TidDateMonthAug ->
            "Aug"

        TidDateMonthDec ->
            "Dec"

        TidDateMonthFeb ->
            "Feb"

        TidDateMonthJan ->
            "Jan"

        TidDateMonthJul ->
            "Jul"

        TidDateMonthJun ->
            "Jun"

        TidDateMonthMar ->
            "Mar"

        TidDateMonthMay ->
            "May"

        TidDateMonthNov ->
            "Nov"

        TidDateMonthOct ->
            "Oct"

        TidDateMonthSep ->
            "Sep"

        TidDiaryAddFood ->
            "+ Add Food"

        TidDiaryCalendarCompactThousands ->
            "k"

        TidDiaryCalendarDayAriaLogged hole0 hole1 ->
            hole0 ++ ", " ++ hole1 ++ " kilocalories logged"

        TidDiaryCalendarDayAriaNoFood hole0 ->
            hole0 ++ ", no food logged"

        TidDiaryCalendarLoadEarlier ->
            "Load earlier"

        TidDiaryCalendarWeekdayFri ->
            "F"

        TidDiaryCalendarWeekdayMon ->
            "M"

        TidDiaryCalendarWeekdaySat ->
            "S"

        TidDiaryCalendarWeekdaySun ->
            "S"

        TidDiaryCalendarWeekdayThu ->
            "T"

        TidDiaryCalendarWeekdayTue ->
            "T"

        TidDiaryCalendarWeekdayWed ->
            "W"

        TidDiaryCalories ->
            "CALORIES"

        TidDiaryCarbs ->
            "Carbs"

        TidDiaryDetails ->
            "Details"

        TidDiaryGoalMet ->
            "Goal met"

        TidDiaryKcal hole0 ->
            hole0 ++ " kcal"

        TidDiaryKcalEaten ->
            "kcal eaten"

        TidDiaryKcalLeft hole0 ->
            hole0 ++ " kcal left"

        TidDiaryKcalOver hole0 ->
            hole0 ++ " kcal over"

        TidDiaryLogLatestFrom hole0 ->
            "Log latest from " ++ hole0

        TidDiaryLogging ->
            "Logging..."

        TidDiaryMacroGrams hole0 ->
            hole0 ++ " g"

        TidDiaryMacroGramsWithTarget hole0 hole1 ->
            hole0 ++ " / " ++ hole1 ++ " g"

        TidDiaryMacroSummaryGrams hole0 hole1 hole2 ->
            "carbs " ++ hole0 ++ "g ⋅ protein " ++ hole1 ++ "g ⋅ fat " ++ hole2 ++ "g"

        TidDiaryMacroSummaryPercent hole0 hole1 hole2 ->
            "carbs " ++ hole0 ++ "% ⋅ protein " ++ hole1 ++ "% ⋅ fat " ++ hole2 ++ "%"

        TidDiaryNextDay ->
            "Next Day"

        TidDiaryNoItems ->
            "No items"

        TidDiaryOfKcal hole0 ->
            "of " ++ hole0 ++ " kcal"

        TidDiaryOther ->
            "Other"

        TidDiaryPreviousDay ->
            "Previous Day"

        TidDiarySettingsMealSlotsDescription ->
            "Choose the fixed meal slots shown in your diary."

        TidDiarySettingsMealSlotsTitle ->
            "Meal slots"

        TidDiarySettingsSave ->
            "Save meal slots"

        TidDiarySettingsSaved ->
            "Saved"

        TidDiarySettingsSelectAtLeastOne ->
            "Select at least one meal slot."

        TidFoodEditorAddCategory ->
            "Add category"

        TidFoodEditorAddNutrient ->
            "+ Add Nutrient"

        TidFoodEditorAddRowHint ->
            "Enter calories and macros (per 100g) to save."

        TidFoodEditorAddServing ->
            "+ Add Serving"

        TidFoodEditorAmountForPortion ->
            "Amount for this portion"

        TidFoodEditorAmountPer100g ->
            "Amount per 100 g"

        TidFoodEditorBasicInfo ->
            "Basic Info"

        TidFoodEditorBrand ->
            "Brand"

        TidFoodEditorCategories ->
            "Categories"

        TidFoodEditorCategoriesHint ->
            "Enter (or click Add) to tag this food."

        TidFoodEditorDateLabel ->
            "Date (YYYY-MM-DD)"

        TidFoodEditorDefaultPortion ->
            "Default Portion"

        TidFoodEditorDefaultPortionHint100g ->
            "Optional. Food logging will start at 100 g."

        TidFoodEditorDefaultPortionHintCount ->
            "Enter how many of the selected serving to prefill."

        TidFoodEditorDefaultPortionHintGrams ->
            "Enter the gram amount to prefill when logging this food."

        TidFoodEditorDefaultPortionHintServing ->
            "Optional. Food logging will start with the first serving."

        TidFoodEditorDefaultQuantity ->
            "Default Quantity"

        TidFoodEditorDefaultUnit ->
            "Default Unit"

        TidFoodEditorErrorDuplicateNutrient ->
            "Each nutrient can only be added once."

        TidFoodEditorErrorDuplicateServingUnit hole0 ->
            "Each serving must use a unique unit (duplicate: " ++ hole0 ++ ")"

        TidFoodEditorErrorFoodNameRequired ->
            "Food name is required."

        TidFoodEditorErrorGreaterThanZero hole0 ->
            hole0 ++ " must be greater than zero."

        TidFoodEditorErrorInvalidDate ->
            "Enter a valid date in YYYY-MM-DD format."

        TidFoodEditorErrorInvalidDefaultPortion ->
            "Default portion must be grams or use a configured serving unit"

        TidFoodEditorErrorMissingCoreMacros ->
            "The estimate is missing calories or a required macronutrient."

        TidFoodEditorErrorNameRequired ->
            "Name is required"

        TidFoodEditorErrorNotConfigured ->
            "This editor is not configured for food logging."

        TidFoodEditorErrorNumberGreaterThanZero hole0 ->
            hole0 ++ " must be a number greater than zero."

        TidFoodEditorErrorNutrientAmountNonNegative hole0 ->
            "Nutrient amount must be a non-negative number (got: " ++ hole0 ++ ")"

        TidFoodEditorErrorNutrientRequired hole0 ->
            hole0 ++ " is required."

        TidFoodEditorErrorPortionTooLarge ->
            "The portion values are too large to calculate safely."

        TidFoodEditorErrorPortionWeightRequired ->
            "Weight of this logged portion is required."

        TidFoodEditorErrorRequiredNumber hole0 ->
            hole0 ++ " is required and must be a number."

        TidFoodEditorErrorSelectNutrient ->
            "Select a nutrient for every entered amount."

        TidFoodEditorErrorServingGramsPositive hole0 ->
            "Grams per serving unit must be a positive number (got: " ++ hole0 ++ ")"

        TidFoodEditorErrorUnsupportedNutrient hole0 ->
            "The estimate contains an unsupported nutrient: " ++ hole0

        TidFoodEditorErrorZeroOrGreater hole0 ->
            hole0 ++ " must be zero or greater."

        TidFoodEditorGrams ->
            "Grams"

        TidFoodEditorGramsPerUnit ->
            "Grams per unit"

        TidFoodEditorLabelEstimatedNutrient ->
            "Estimated nutrient"

        TidFoodEditorLabelPortionWeight ->
            "Weight of this logged portion"

        TidFoodEditorLabelSuggestedPortionWeight ->
            "Suggested portion weight"

        TidFoodEditorLogDetails ->
            "Log Details"

        TidFoodEditorLoggedPortion ->
            "Logged Portion"

        TidFoodEditorLoggedPortionHint ->
            "Describe the entire amount you are logging."

        TidFoodEditorMealNone ->
            "None"

        TidFoodEditorName ->
            "Name"

        TidFoodEditorNoCategories ->
            "No categories yet"

        TidFoodEditorNoDefault ->
            "No default"

        TidFoodEditorNotes ->
            "Notes (optional)"

        TidFoodEditorNutrientsTitle ->
            "Nutrients"

        TidFoodEditorPortionHint ->
            "Enter totals for the entire logged portion. Calories, protein, carbohydrates, and fat are required."

        TidFoodEditorPortionNutrition ->
            "Portion Nutrition"

        TidFoodEditorPortionUnit ->
            "Portion unit"

        TidFoodEditorPortionWeightLabel ->
            "Weight of this logged portion (g)"

        TidFoodEditorRemove ->
            "Remove"

        TidFoodEditorSaveToFoods ->
            "Save to My Foods"

        TidFoodEditorSaveToFoodsDescription ->
            "Save this as a reusable custom food before logging it."

        TidFoodEditorSelectNutrient ->
            "Select nutrient..."

        TidFoodEditorServings ->
            "Servings"

        TidFoodEditorServingsEmpty ->
            "Add a serving to define portions in cups, pieces, or other units."

        TidFoodEditorUnitPlaceholder ->
            "unit"

        TidFoodEditorUses hole0 ->
            hole0 ++ " uses"

        TidFoodSearchAdHocDescription ->
            "Log a one-off food without saving it to your foods."

        TidFoodSearchAdHocTitle ->
            "Create an ad-hoc food log"

        TidFoodSearchAdding ->
            "Adding..."

        TidFoodSearchBarcodeNotFound ->
            "No food found for that barcode."

        TidFoodSearchCenterBarcode ->
            "Center the barcode on the guide."

        TidFoodSearchEmptyPrompt ->
            "Search for a food to get started."

        TidFoodSearchEnterBarcode ->
            "Enter barcode"

        TidFoodSearchEnterBarcodePrompt ->
            "Enter a barcode to look up a food."

        TidFoodSearchEnterManually ->
            "Enter manually"

        TidFoodSearchErrorCouldNotReadDate ->
            "Could not read selected date."

        TidFoodSearchErrorScannerStart ->
            "Could not start barcode scanner."

        TidFoodSearchNoCustomFoods ->
            "No custom foods found. Try a different search."

        TidFoodSearchNoFoods ->
            "No foods found. Try a different search."

        TidFoodSearchNoLoggedFoods ->
            "No logged foods found. Try a different search."

        TidFoodSearchNoRecents ->
            "No recent foods yet. Search for a food to get started."

        TidFoodSearchOpeningFood ->
            "Opening food."

        TidFoodSearchPromptAll ->
            "Search for a food"

        TidFoodSearchPromptCustom ->
            "Search your custom foods"

        TidFoodSearchPromptHistory ->
            "Search your logged foods"

        TidFoodSearchRecent ->
            "Recent"

        TidFoodSearchResults ->
            "Results"

        TidFoodSearchScan ->
            "Scan"

        TidFoodSearchScopeAll ->
            "All"

        TidFoodSearchScopeBarcode ->
            "Barcode"

        TidFoodSearchScopeCustom ->
            "Custom"

        TidFoodSearchScopeHistory ->
            "History"

        TidFoodSearchSearching ->
            "Searching"

        TidFoodSearchStarting ->
            "Starting"

        TidFoodSearchStartingCamera ->
            "Starting camera..."

        TidFoodShowLogging ->
            "Logging..."

        TidFoodShowPortion ->
            "Portion"

        TidGoalSettingsCalories ->
            "Calories"

        TidGoalSettingsCarbs ->
            "Carbs (g)"

        TidGoalSettingsDailyTargetsTitle ->
            "Daily Targets"

        TidGoalSettingsErrorCaloriesMacros ->
            "Calories must equal protein*4 + carbs*4 + fat*9."

        TidGoalSettingsErrorCaloriesPositive ->
            "Calories must be greater than 0."

        TidGoalSettingsErrorInvalidNumbers ->
            "Enter valid numbers for all goal fields."

        TidGoalSettingsErrorMacrosNonNegative ->
            "Protein, carbs, and fat must be 0 or greater."

        TidGoalSettingsFat ->
            "Fat (g)"

        TidGoalSettingsProtein ->
            "Protein (g)"

        TidGoalSettingsSave ->
            "Save Goals"

        TidGoalSettingsStatusDefaultAfter hole0 ->
            "Using backend defaults after " ++ hole0 ++ "."

        TidGoalSettingsStatusDefaultForDate ->
            "Using backend defaults for this date."

        TidGoalSettingsStatusSavedActive ->
            "Saved goals are active."

        TidGoalSettingsStatusSavedFrom hole0 ->
            "Saved goals effective from " ++ hole0 ++ "."

        TidLoginPasswordRequired ->
            "Password is required"

        TidLoginSubmit ->
            "Log In"

        TidLoginSubmitting ->
            "Logging in..."

        TidLoginTitle ->
            "Log In"

        TidMealSlotBreakfast ->
            "Breakfast"

        TidMealSlotDinner ->
            "Dinner"

        TidMealSlotLateNightSnack ->
            "Late-night Snack"

        TidMealSlotLunch ->
            "Lunch"

        TidMealSlotSnack ->
            "Snack"

        TidNavAdmin ->
            "Admin"

        TidNavBack ->
            "Back"

        TidNavCalendar ->
            "Calendar"

        TidNavDiary ->
            "Diary"

        TidNavFoods ->
            "Foods"

        TidNavGoals ->
            "Goals"

        TidNavLogout ->
            "Logout"

        TidNavMealSlots ->
            "Meal slots"

        TidNavMeals ->
            "Meals"

        TidNavMenu ->
            "Menu"

        TidNavMyFoods ->
            "My Foods"

        TidNavMyMeals ->
            "My Meals"

        TidNavSearch ->
            "Search"

        TidNavSearchFoods ->
            "Search Foods"

        TidNutrientAddedSugars ->
            "Added Sugars"

        TidNutrientCalcium ->
            "Calcium"

        TidNutrientCarbRich ->
            "Carb-rich"

        TidNutrientCarbohydrates ->
            "Carbohydrates"

        TidNutrientCholesterol ->
            "Cholesterol"

        TidNutrientEnergy ->
            "Energy"

        TidNutrientFat ->
            "Fat"

        TidNutrientFatRich ->
            "Fat-rich"

        TidNutrientFiber ->
            "Fiber"

        TidNutrientFolate ->
            "Folate"

        TidNutrientIron ->
            "Iron"

        TidNutrientLegendCarbs hole0 ->
            "Carbs " ++ hole0 ++ "g"

        TidNutrientLegendFat hole0 ->
            "Fat " ++ hole0 ++ "g"

        TidNutrientLegendProtein hole0 ->
            "Protein " ++ hole0 ++ "g"

        TidNutrientMagnesium ->
            "Magnesium"

        TidNutrientMonounsaturatedFat ->
            "Monounsaturated Fat"

        TidNutrientNutrition ->
            "Nutrition"

        TidNutrientPhosphorus ->
            "Phosphorus"

        TidNutrientPolyunsaturatedFat ->
            "Polyunsaturated Fat"

        TidNutrientPotassium ->
            "Potassium"

        TidNutrientProtein ->
            "Protein"

        TidNutrientProteinRich ->
            "Protein-rich"

        TidNutrientSaturatedFat ->
            "Saturated Fat"

        TidNutrientSodium ->
            "Sodium"

        TidNutrientStarch ->
            "Starch"

        TidNutrientSugar ->
            "Sugar"

        TidNutrientTableAmount ->
            "Amount"

        TidNutrientTableNutrient ->
            "Nutrient"

        TidNutrientTableUnit ->
            "Unit"

        TidNutrientTransFat ->
            "Trans Fat"

        TidNutrientUnavailable ->
            "Unavailable"

        TidNutrientVitaminA ->
            "Vitamin A"

        TidNutrientVitaminB12 ->
            "Vitamin B12"

        TidNutrientVitaminB6 ->
            "Vitamin B6"

        TidNutrientVitaminC ->
            "Vitamin C"

        TidNutrientVitaminD ->
            "Vitamin D"

        TidNutrientVitaminE ->
            "Vitamin E"

        TidNutrientZinc ->
            "Zinc"

        TidSearchKcalPer100g hole0 ->
            hole0 ++ " kcal per 100 g"

        TidSetupDescription ->
            "Create the admin account to get started."

        TidSetupPasswordMinLength ->
            "Password must be at least 8 characters"

        TidSetupSubmit ->
            "Create Admin"

        TidSetupSubmitting ->
            "Creating..."

        TidSetupTitle ->
            "First-Time Setup"

        TidTitleAddToMealSlot hole0 ->
            "Add to " ++ hole0

        TidTitleAdmin ->
            "Admin"

        TidTitleCalendar ->
            "Calendar"

        TidTitleCreateFood ->
            "Create Food"

        TidTitleCreateMeal ->
            "Create Meal"

        TidTitleCreateUser ->
            "Create User"

        TidTitleCreateWithAi ->
            "Create with AI"

        TidTitleDiary ->
            "Diary"

        TidTitleDiarySettings ->
            "Diary settings"

        TidTitleEditFood ->
            "Edit Food"

        TidTitleEditLog ->
            "Edit Log"

        TidTitleEditMeal ->
            "Edit Meal"

        TidTitleEditUser ->
            "Edit User"

        TidTitleFood ->
            "Food"

        TidTitleGoals ->
            "Goals"

        TidTitleLogFood ->
            "Log Food"

        TidTitleLogWithAi ->
            "Log with AI"

        TidTitleLogin ->
            "Login"

        TidTitleManualFoodLog ->
            "Manual Food Log"

        TidTitleMeal ->
            "Meal"

        TidTitleMyFoods ->
            "My Foods"

        TidTitleMyMeals ->
            "My Meals"

        TidTitleNutritionDetails ->
            "Nutrition details"

        TidTitleSearchFoods ->
            "Search Foods"

        TidTitleSetup ->
            "Setup"

        TidUiCategoryOverflowMore hole0 ->
            "+" ++ hole0 ++ " more"

        TidUiDetailRowLabelSuffix hole0 ->
            hole0 ++ ":"

        TidUiRemoveNamed hole0 ->
            "Remove " ++ hole0

        TidUiRetry ->
            "Retry"

        TidUiSelectPlaceholder ->
            "Select…"

        TidUiUnitWithCode hole0 hole1 ->
            hole0 ++ " (" ++ hole1 ++ ")"

        TidUsersCreateUser ->
            "+ Create User"

        TidUsersCredentials ->
            "Credentials"

        TidUsersDisableConfirmDescription ->
            "This user will no longer be able to sign in."

        TidUsersDisableConfirmTitle ->
            "Disable user?"

        TidUsersDisableUser ->
            "Disable User"

        TidUsersDisabling ->
            "Disabling..."

        TidUsersDisplayNameRequired ->
            "Display name is required"

        TidUsersEnableUser ->
            "Enable User"

        TidUsersEnabling ->
            "Enabling..."

        TidUsersInitialPassword ->
            "Initial Password"

        TidUsersInitialPasswordRequired ->
            "Initial password is required"

        TidUsersLoadFailed hole0 ->
            "Unable to load user: " ++ hole0

        TidUsersNewPassword ->
            "New password"

        TidUsersNewPasswordRequired ->
            "New password is required"

        TidUsersResetPassword ->
            "Reset Password"

        TidUsersResetting ->
            "Resetting..."

        TidUsersSectionTitle ->
            "Users"
