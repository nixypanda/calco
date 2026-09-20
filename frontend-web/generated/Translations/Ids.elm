module Translations.Ids exposing (TranslationId(..))


type TranslationId
    = TidApiErrorBadBody
    | TidApiErrorBadUrl
    | TidApiErrorNetwork
    | TidApiErrorRateLimited
    | TidApiErrorRateLimitedSeconds String
    | TidApiErrorServer
    | TidApiErrorTimeout
    | TidCalendarMonthApril
    | TidCalendarMonthAugust
    | TidCalendarMonthDecember
    | TidCalendarMonthFebruary
    | TidCalendarMonthJanuary
    | TidCalendarMonthJuly
    | TidCalendarMonthJune
    | TidCalendarMonthMarch
    | TidCalendarMonthMay
    | TidCalendarMonthNovember
    | TidCalendarMonthOctober
    | TidCalendarMonthSeptember
    | TidCalendarMonthYear String String
    | TidCommonCancel
    | TidCommonClose
    | TidCommonCreated
    | TidCommonDisplayName
    | TidCommonNewVersionAvailable
    | TidCommonPassword
    | TidCommonProfile
    | TidCommonRouteNotMigrated
    | TidCommonSave
    | TidCommonSaving
    | TidCommonSignedIn
    | TidCommonSignedInAs String
    | TidCommonStatus
    | TidCommonTapToRefresh
    | TidCommonUseDarkTheme
    | TidCommonUsername
    | TidCommonUsernameRequired
    | TidDateMonthApr
    | TidDateMonthAug
    | TidDateMonthDec
    | TidDateMonthFeb
    | TidDateMonthJan
    | TidDateMonthJul
    | TidDateMonthJun
    | TidDateMonthMar
    | TidDateMonthMay
    | TidDateMonthNov
    | TidDateMonthOct
    | TidDateMonthSep
    | TidDiarySettingsMealSlotsDescription
    | TidDiarySettingsMealSlotsTitle
    | TidDiarySettingsSave
    | TidDiarySettingsSaved
    | TidDiarySettingsSelectAtLeastOne
    | TidGoalSettingsCalories
    | TidGoalSettingsCarbs
    | TidGoalSettingsDailyTargetsTitle
    | TidGoalSettingsErrorCaloriesMacros
    | TidGoalSettingsErrorCaloriesPositive
    | TidGoalSettingsErrorInvalidNumbers
    | TidGoalSettingsErrorMacrosNonNegative
    | TidGoalSettingsFat
    | TidGoalSettingsProtein
    | TidGoalSettingsSave
    | TidGoalSettingsStatusDefaultAfter String
    | TidGoalSettingsStatusDefaultForDate
    | TidGoalSettingsStatusSavedActive
    | TidGoalSettingsStatusSavedFrom String
    | TidLoginPasswordRequired
    | TidLoginSubmit
    | TidLoginSubmitting
    | TidLoginTitle
    | TidMealSlotBreakfast
    | TidMealSlotDinner
    | TidMealSlotLateNightSnack
    | TidMealSlotLunch
    | TidMealSlotSnack
    | TidNavAdmin
    | TidNavBack
    | TidNavCalendar
    | TidNavDiary
    | TidNavFoods
    | TidNavGoals
    | TidNavLogout
    | TidNavMealSlots
    | TidNavMeals
    | TidNavMenu
    | TidNavMyFoods
    | TidNavMyMeals
    | TidNavSearch
    | TidNavSearchFoods
    | TidNutrientAddedSugars
    | TidNutrientCalcium
    | TidNutrientCarbRich
    | TidNutrientCarbohydrates
    | TidNutrientCholesterol
    | TidNutrientEnergy
    | TidNutrientFat
    | TidNutrientFatRich
    | TidNutrientFiber
    | TidNutrientFolate
    | TidNutrientIron
    | TidNutrientLegendCarbs String
    | TidNutrientLegendFat String
    | TidNutrientLegendProtein String
    | TidNutrientMagnesium
    | TidNutrientMonounsaturatedFat
    | TidNutrientNutrition
    | TidNutrientPhosphorus
    | TidNutrientPolyunsaturatedFat
    | TidNutrientPotassium
    | TidNutrientProtein
    | TidNutrientProteinRich
    | TidNutrientSaturatedFat
    | TidNutrientSodium
    | TidNutrientStarch
    | TidNutrientSugar
    | TidNutrientTableAmount
    | TidNutrientTableNutrient
    | TidNutrientTableUnit
    | TidNutrientTransFat
    | TidNutrientUnavailable
    | TidNutrientVitaminA
    | TidNutrientVitaminB12
    | TidNutrientVitaminB6
    | TidNutrientVitaminC
    | TidNutrientVitaminD
    | TidNutrientVitaminE
    | TidNutrientZinc
    | TidSearchKcalPer100g String
    | TidSetupDescription
    | TidSetupPasswordMinLength
    | TidSetupSubmit
    | TidSetupSubmitting
    | TidSetupTitle
    | TidTitleAddToMealSlot String
    | TidTitleAdmin
    | TidTitleCalendar
    | TidTitleCreateFood
    | TidTitleCreateMeal
    | TidTitleCreateUser
    | TidTitleCreateWithAi
    | TidTitleDiary
    | TidTitleDiarySettings
    | TidTitleEditFood
    | TidTitleEditLog
    | TidTitleEditMeal
    | TidTitleEditUser
    | TidTitleFood
    | TidTitleGoals
    | TidTitleLogFood
    | TidTitleLogWithAi
    | TidTitleLogin
    | TidTitleManualFoodLog
    | TidTitleMeal
    | TidTitleMyFoods
    | TidTitleMyMeals
    | TidTitleNutritionDetails
    | TidTitleSearchFoods
    | TidTitleSetup
    | TidUiCategoryOverflowMore String
    | TidUiDetailRowLabelSuffix String
    | TidUiRemoveNamed String
    | TidUiRetry
    | TidUiSelectPlaceholder
    | TidUiUnitWithCode String String
    | TidUsersCreateUser
    | TidUsersCredentials
    | TidUsersDisableConfirmDescription
    | TidUsersDisableConfirmTitle
    | TidUsersDisableUser
    | TidUsersDisabling
    | TidUsersDisplayNameRequired
    | TidUsersEnableUser
    | TidUsersEnabling
    | TidUsersInitialPassword
    | TidUsersInitialPasswordRequired
    | TidUsersLoadFailed String
    | TidUsersNewPassword
    | TidUsersNewPasswordRequired
    | TidUsersResetPassword
    | TidUsersResetting
    | TidUsersSectionTitle
