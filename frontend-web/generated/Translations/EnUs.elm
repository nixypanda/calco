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

        TidCommonDisplayName ->
            "Display Name"

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
