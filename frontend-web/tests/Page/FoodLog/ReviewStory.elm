module Page.FoodLog.ReviewStory exposing
    ( AdHocRequest
    , CreateFoodProjection
    , adHocRequest
    , catalog
    , createFoodRequest
    , dateOf
    , day
    , fillNutrients
    , gram
    , nameRequired
    , productLogItemId
    , retryLabel
    , savedNotLogged
    , serving
    , submitError
    , submitLabel
    , units
    )

{-| Projections and fixtures shared by the two review screens
(`Page.FoodLog.CreateAdHoc` and its AI wrapper).
-}

import Api.Foods exposing (CreateFoodRequest, NutrientItem, UnitItem)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Component.FoodEditor as Editor
import Data.MealSlot as MealSlot
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.FoodLog.CreateAdHoc as Review
import Support.Fixtures as Fixtures
import Translations.Ids exposing (TranslationId(..))


dateOf : Review.Model -> String
dateOf model =
    Maybe.withDefault "" (Maybe.map .date (logFields model))


submitLabel : Review.Model -> Maybe String
submitLabel model =
    case model.submit of
        Review.LogFailedAfterFoodSaved _ ->
            Just retryLabel

        Review.AwaitingLocalCtx ->
            Just (I18n.en TidFoodShowLogging)

        Review.LoggingAdHoc ->
            Just (I18n.en TidFoodShowLogging)

        Review.SavingCustomFood ->
            Just (I18n.en TidFoodShowLogging)

        Review.LoggingSavedFood _ ->
            Just (I18n.en TidFoodShowLogging)

        Review.SubmitIdle ->
            Just logFoodLabel

        Review.SubmitFailed _ ->
            Just logFoodLabel


submitError : Review.Model -> Maybe String
submitError model =
    case model.submit of
        Review.SubmitFailed message ->
            Just message

        Review.LogFailedAfterFoodSaved saved ->
            Just saved.message

        _ ->
            Nothing


logFields : Review.Model -> Maybe Editor.LogFields
logFields model =
    case model.form.ctx of
        Editor.FoodLogCtx fields _ ->
            Just fields

        Editor.CustomFoodCtx ->
            Nothing


type alias AdHocRequest =
    { name : String
    , date : String
    , timezone : Maybe String
    , mealSlot : Maybe String
    , amount : String
    , unit : String
    , nutrients : List String
    , notes : Maybe String
    }


adHocRequest : CreateAdHocLogRequest -> AdHocRequest
adHocRequest request =
    { name = request.name
    , date = LocalDate.format request.logDate
    , timezone = request.deviceTimezone
    , mealSlot = Maybe.map MealSlot.toString request.mealSlot
    , amount = request.quantity.amount
    , unit = request.quantity.unit
    , nutrients = List.map (\item -> item.code ++ ":" ++ item.amount) request.nutrients
    , notes = request.notes
    }


type alias CreateFoodProjection =
    { name : String
    , defaultUnit : Maybe String
    , defaultQuantity : Maybe String
    , servings : List String
    }


createFoodRequest : CreateFoodRequest -> CreateFoodProjection
createFoodRequest request =
    { name = request.name
    , defaultUnit = request.defaultUnit
    , defaultQuantity = request.defaultQuantity
    , servings =
        List.map
            (\entry -> entry.unit ++ ":" ++ String.fromFloat entry.gramsPerUnit)
            request.servings
    }


productLogItemId : CreateLogRequest -> String
productLogItemId request =
    request.item.id


day : LocalDate
day =
    Fixtures.date "2026-09-14"


catalog : List NutrientItem
catalog =
    [ nutrient "ENERGY_KCAL" "Calories" "kcal"
    , nutrient "PROTEIN_G" "Protein" "g"
    , nutrient "CARBS_G" "Carbohydrates" "g"
    , nutrient "FAT_G" "Fat" "g"
    , nutrient "FIBER_G" "Fiber" "g"
    ]


nutrient : String -> String -> String -> NutrientItem
nutrient code name unit =
    { code = code, name = name, unit = unit, category = "Core" }


units : List UnitItem
units =
    [ gram, serving ]


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


serving : UnitItem
serving =
    { code = "serving", name = "Serving", kind = "serving" }


fillNutrients : List Review.Msg
fillNutrients =
    [ Review.FormMsg (Editor.NutrientAmountChanged 0 "520")
    , Review.FormMsg (Editor.NutrientAmountChanged 1 "24")
    , Review.FormMsg (Editor.NutrientAmountChanged 2 "48")
    , Review.FormMsg (Editor.NutrientAmountChanged 3 "25")
    ]


logFoodLabel : String
logFoodLabel =
    I18n.en TidTitleLogFood


retryLabel : String
retryLabel =
    I18n.en TidFoodLogRetryLogging


nameRequired : String
nameRequired =
    I18n.en TidFoodEditorErrorFoodNameRequired


savedNotLogged : String
savedNotLogged =
    I18n.en TidFoodLogSavedNotLogged
