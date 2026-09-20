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
    | TidCommonCreating
    | TidCommonDisplayName
    | TidCommonLoading
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
    | TidCustomFoodConfirmDelete
    | TidCustomFoodDelete
    | TidCustomFoodDeleteConfirmDescription
    | TidCustomFoodDeleteConfirmTitle
    | TidCustomFoodDeleting
    | TidCustomFoodDuplicateServingUnit String
    | TidCustomFoodEnterManually
    | TidCustomFoodInvalidDefaultPortion
    | TidCustomFoodInvalidNutrientAmount String
    | TidCustomFoodInvalidServingGrams String
    | TidCustomFoodListEmpty
    | TidCustomFoodNameRequired
    | TidCustomFoodSave
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
    | TidDiaryAddFood
    | TidDiaryCalendarCompactThousands
    | TidDiaryCalendarDayAriaLogged String String
    | TidDiaryCalendarDayAriaNoFood String
    | TidDiaryCalendarLoadEarlier
    | TidDiaryCalendarWeekdayFri
    | TidDiaryCalendarWeekdayMon
    | TidDiaryCalendarWeekdaySat
    | TidDiaryCalendarWeekdaySun
    | TidDiaryCalendarWeekdayThu
    | TidDiaryCalendarWeekdayTue
    | TidDiaryCalendarWeekdayWed
    | TidDiaryCalories
    | TidDiaryCarbs
    | TidDiaryDetails
    | TidDiaryGoalMet
    | TidDiaryKcal String
    | TidDiaryKcalEaten
    | TidDiaryKcalLeft String
    | TidDiaryKcalOver String
    | TidDiaryLogLatestFrom String
    | TidDiaryLogging
    | TidDiaryMacroGrams String
    | TidDiaryMacroGramsWithTarget String String
    | TidDiaryMacroSummaryGrams String String String
    | TidDiaryMacroSummaryPercent String String String
    | TidDiaryNextDay
    | TidDiaryNoItems
    | TidDiaryOfKcal String
    | TidDiaryOther
    | TidDiaryPreviousDay
    | TidDiarySettingsMealSlotsDescription
    | TidDiarySettingsMealSlotsTitle
    | TidDiarySettingsSave
    | TidDiarySettingsSaved
    | TidDiarySettingsSelectAtLeastOne
    | TidFoodEditorAddCategory
    | TidFoodEditorAddNutrient
    | TidFoodEditorAddRowHint
    | TidFoodEditorAddServing
    | TidFoodEditorAmountForPortion
    | TidFoodEditorAmountPer100g
    | TidFoodEditorBasicInfo
    | TidFoodEditorBrand
    | TidFoodEditorCategories
    | TidFoodEditorCategoriesHint
    | TidFoodEditorDateLabel
    | TidFoodEditorDefaultPortion
    | TidFoodEditorDefaultPortionHint100g
    | TidFoodEditorDefaultPortionHintCount
    | TidFoodEditorDefaultPortionHintGrams
    | TidFoodEditorDefaultPortionHintServing
    | TidFoodEditorDefaultQuantity
    | TidFoodEditorDefaultUnit
    | TidFoodEditorErrorDuplicateNutrient
    | TidFoodEditorErrorDuplicateServingUnit String
    | TidFoodEditorErrorFoodNameRequired
    | TidFoodEditorErrorGreaterThanZero String
    | TidFoodEditorErrorInvalidDate
    | TidFoodEditorErrorInvalidDefaultPortion
    | TidFoodEditorErrorMissingCoreMacros
    | TidFoodEditorErrorNameRequired
    | TidFoodEditorErrorNotConfigured
    | TidFoodEditorErrorNumberGreaterThanZero String
    | TidFoodEditorErrorNutrientAmountNonNegative String
    | TidFoodEditorErrorNutrientRequired String
    | TidFoodEditorErrorPortionTooLarge
    | TidFoodEditorErrorPortionWeightRequired
    | TidFoodEditorErrorRequiredNumber String
    | TidFoodEditorErrorSelectNutrient
    | TidFoodEditorErrorServingGramsPositive String
    | TidFoodEditorErrorUnsupportedNutrient String
    | TidFoodEditorErrorZeroOrGreater String
    | TidFoodEditorGrams
    | TidFoodEditorGramsPerUnit
    | TidFoodEditorLabelEstimatedNutrient
    | TidFoodEditorLabelPortionWeight
    | TidFoodEditorLabelSuggestedPortionWeight
    | TidFoodEditorLogDetails
    | TidFoodEditorLoggedPortion
    | TidFoodEditorLoggedPortionHint
    | TidFoodEditorMealNone
    | TidFoodEditorName
    | TidFoodEditorNoCategories
    | TidFoodEditorNoDefault
    | TidFoodEditorNotes
    | TidFoodEditorNutrientsTitle
    | TidFoodEditorPortionHint
    | TidFoodEditorPortionNutrition
    | TidFoodEditorPortionUnit
    | TidFoodEditorPortionWeightLabel
    | TidFoodEditorRemove
    | TidFoodEditorSaveToFoods
    | TidFoodEditorSaveToFoodsDescription
    | TidFoodEditorSelectNutrient
    | TidFoodEditorServings
    | TidFoodEditorServingsEmpty
    | TidFoodEditorUnitPlaceholder
    | TidFoodEditorUses String
    | TidFoodSearchAdHocDescription
    | TidFoodSearchAdHocTitle
    | TidFoodSearchAdding
    | TidFoodSearchBarcodeNotFound
    | TidFoodSearchCenterBarcode
    | TidFoodSearchEmptyPrompt
    | TidFoodSearchEnterBarcode
    | TidFoodSearchEnterBarcodePrompt
    | TidFoodSearchEnterManually
    | TidFoodSearchErrorCouldNotReadDate
    | TidFoodSearchErrorScannerStart
    | TidFoodSearchNoCustomFoods
    | TidFoodSearchNoFoods
    | TidFoodSearchNoLoggedFoods
    | TidFoodSearchNoRecents
    | TidFoodSearchOpeningFood
    | TidFoodSearchPromptAll
    | TidFoodSearchPromptCustom
    | TidFoodSearchPromptHistory
    | TidFoodSearchRecent
    | TidFoodSearchResults
    | TidFoodSearchScan
    | TidFoodSearchScopeAll
    | TidFoodSearchScopeBarcode
    | TidFoodSearchScopeCustom
    | TidFoodSearchScopeHistory
    | TidFoodSearchSearching
    | TidFoodSearchStarting
    | TidFoodSearchStartingCamera
    | TidFoodShowLogging
    | TidFoodShowPortion
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
