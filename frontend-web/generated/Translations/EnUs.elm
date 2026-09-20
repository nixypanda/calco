module Translations.EnUs exposing (enUsTranslations)

import Translations.Ids exposing (TranslationId(..))


enUsTranslations : TranslationId -> String
enUsTranslations tid =
    case tid of
        TidCommonCancel ->
            "Cancel"

        TidCommonClose ->
            "Close"

        TidCommonNewVersionAvailable ->
            "New version available"

        TidCommonProfile ->
            "Profile"

        TidCommonRouteNotMigrated ->
            "This route is not migrated yet."

        TidCommonSignedIn ->
            "Signed in"

        TidCommonSignedInAs hole0 ->
            "Signed in as " ++ hole0

        TidCommonTapToRefresh ->
            "Tap to refresh"

        TidCommonUseDarkTheme ->
            "Use dark theme"

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
