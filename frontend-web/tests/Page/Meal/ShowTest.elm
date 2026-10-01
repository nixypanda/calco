module Page.Meal.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Meals exposing (Meal, MealNutritionResponse)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Page.Meal.Show as MealShow
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients exposing (NutritionState(..), nutritionInput)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


tests : Test
tests =
    describe "Page.Meal.Show"
        [ test "loading a meal falls back to default units and requests the first product" <|
            \_ ->
                let
                    ( loading, initial ) =
                        MealShow.init "meal-1"

                    withUnits : MealShow.Model
                    withUnits =
                        step (MealShow.UnitsLoaded (Ok { items = [] })) loading

                    loaded : MealShow.Model
                    loaded =
                        step
                            (MealShow.MealLoaded "meal-1" (Ok repeatedProductMeal))
                            withUnits

                    request : MealShow.OutMsg
                    request =
                        out
                            (MealShow.MealLoaded "meal-1" (Ok repeatedProductMeal))
                            withUnits
                in
                { initial = initial
                , uniqueIds = MealShow.uniqueProductIds repeatedProductMeal
                , units = toScreen withUnits |> .units
                , phase = toScreen loaded |> .phase
                , request = request
                }
                    |> Expect.equal
                        { initial = MealShow.RequestInitialData "meal-1"
                        , uniqueIds = [ "food-1" ]
                        , units = Just [ fallbackGram ]
                        , phase = "loaded"
                        , request = MealShow.RequestProductDetail "food-1"
                        }
        , test "the product-name chain records a failed lookup and continues to the last" <|
            \_ ->
                let
                    loading : MealShow.Model
                    loading =
                        Tuple.first (MealShow.init "meal-1")

                    loaded : MealShow.Model
                    loaded =
                        step (MealShow.MealLoaded "meal-1" (Ok twoProductMeal)) loading

                    afterFailure : MealShow.Model
                    afterFailure =
                        step
                            (MealShow.ProductDetailLoaded "food-1" (Err Client.NetworkError))
                            loaded

                    afterLast : MealShow.Model
                    afterLast =
                        step (MealShow.ProductDetailLoaded "food-2" (Ok banana)) afterFailure
                in
                { failedName = nameFor "food-1" afterFailure
                , continueRequest =
                    out (MealShow.ProductDetailLoaded "food-1" (Err Client.NetworkError)) loaded
                , chainEnd =
                    out (MealShow.ProductDetailLoaded "food-2" (Ok banana)) afterFailure
                , lastName = nameFor "food-2" afterLast
                }
                    |> Expect.equal
                        { failedName = I18n.en TidMealUnknownFood
                        , continueRequest = MealShow.RequestProductDetail "food-2"
                        , chainEnd = MealShow.NoOp
                        , lastName = "Banana"
                        }
        , test "a response for another meal and a late success after failure are ignored" <|
            \_ ->
                let
                    loading : MealShow.Model
                    loading =
                        Tuple.first (MealShow.init "meal-1")

                    afterOther : MealShow.Model
                    afterOther =
                        step (MealShow.MealLoaded "other" (Ok meal)) loading

                    failed : MealShow.Model
                    failed =
                        step (MealShow.MealLoaded "meal-1" (Err Client.NetworkError)) loading

                    afterLateSuccess : MealShow.Model
                    afterLateSuccess =
                        step (MealShow.MealLoaded "meal-1" (Ok meal)) failed
                in
                { otherPhase = toScreen afterOther |> .phase
                , otherRequest = out (MealShow.MealLoaded "other" (Ok meal)) loading
                , lateSuccessPhase = toScreen afterLateSuccess |> .phase
                , lateSuccessError = toScreen afterLateSuccess |> .error
                }
                    |> Expect.equal
                        { otherPhase = "loading"
                        , otherRequest = MealShow.NoOp
                        , lateSuccessPhase = "failed"
                        , lateSuccessError = Just networkErrorMessage
                        }
        , test "an unauthorized meal load or preview expires the session" <|
            \_ ->
                let
                    loading : MealShow.Model
                    loading =
                        Tuple.first (MealShow.init "meal-1")
                in
                ( out (MealShow.MealLoaded "meal-1" (Err unauthorized)) loading
                , out (MealShow.NutrientPreviewLoaded "meal-1" (Err unauthorized)) loadedMealModel
                )
                    |> Expect.equal ( MealShow.SessionExpired, MealShow.SessionExpired )
        , test "changing amount or unit updates the shown totals and ignores stale responses" <|
            \_ ->
                let
                    afterAmount : MealShow.Model
                    afterAmount =
                        step (MealShow.AmountChanged "150") nutritionLoadedModel

                    staleIgnored : MealShow.Model
                    staleIgnored =
                        applyPreview "100" "g" [ nutrient ] afterAmount

                    amountApplied : MealShow.Model
                    amountApplied =
                        applyPreview "150" "g" [ scaledNutrient ] afterAmount

                    afterUnit : MealShow.Model
                    afterUnit =
                        step (MealShow.UnitChanged "serving") amountApplied

                    unitApplied : MealShow.Model
                    unitApplied =
                        applyPreview "150" "serving" [ servingNutrient ] afterUnit
                in
                { initialNutrients = toScreen nutritionLoadedModel |> .nutrients
                , amountRequest = out (MealShow.AmountChanged "150") nutritionLoadedModel
                , amountNutrition = toScreen amountApplied |> .nutrition
                , amountNutrients = toScreen amountApplied |> .nutrients
                , staleNutrition = toScreen staleIgnored |> .nutrition
                , unitRequest = out (MealShow.UnitChanged "serving") amountApplied
                , unitAmount = toScreen unitApplied |> .amount
                , unitNutrients = toScreen unitApplied |> .nutrients
                }
                    |> Expect.equal
                        { initialNutrients = Just [ nutrient ]
                        , amountRequest = MealShow.RequestNutrientPreview "meal-1" "150" "g"
                        , amountNutrition = "loaded"
                        , amountNutrients = Just [ scaledNutrient ]
                        , staleNutrition = "loading"
                        , unitRequest = MealShow.RequestNutrientPreview "meal-1" "150" "serving"
                        , unitAmount = Just "150"
                        , unitNutrients = Just [ servingNutrient ]
                        }
        , test "an invalid or non-positive amount clears the displayed preview without a request" <|
            \_ ->
                let
                    invalid : MealShow.Model
                    invalid =
                        step (MealShow.AmountChanged "nope") nutritionLoadedModel

                    zero : MealShow.Model
                    zero =
                        step (MealShow.AmountChanged "0") nutritionLoadedModel
                in
                { invalidRequest = out (MealShow.AmountChanged "nope") nutritionLoadedModel
                , invalidNutrition = toScreen invalid |> .nutrition
                , invalidNutrients = toScreen invalid |> .nutrients
                , zeroRequest = out (MealShow.AmountChanged "0") nutritionLoadedModel
                , zeroNutrition = toScreen zero |> .nutrition
                }
                    |> Expect.equal
                        { invalidRequest = MealShow.NoOp
                        , invalidNutrition = "unavailable"
                        , invalidNutrients = Nothing
                        , zeroRequest = MealShow.NoOp
                        , zeroNutrition = "unavailable"
                        }
        , test "deleting a meal confirms, requests, and navigates to the list on success" <|
            \_ ->
                let
                    confirming : MealShow.Model
                    confirming =
                        step MealShow.DeleteClicked loadedMealModel

                    deleting : MealShow.Model
                    deleting =
                        step MealShow.ConfirmDeleteClicked confirming
                in
                { confirmState = toScreen confirming |> .delete
                , request = out MealShow.ConfirmDeleteClicked confirming
                , deletingState = toScreen deleting |> .delete
                , success = out (MealShow.DeleteCompleted (Ok ())) deleting
                }
                    |> Expect.equal
                        { confirmState = Just DeleteConfirming
                        , request = MealShow.RequestDeleteMeal "meal-1"
                        , deletingState = Just Deleting
                        , success = MealShow.Navigate MealList
                        }
        , test "a failed delete retries, and an unauthorized delete expires the session" <|
            \_ ->
                let
                    deleting : MealShow.Model
                    deleting =
                        loadedMealModel
                            |> step MealShow.DeleteClicked
                            |> step MealShow.ConfirmDeleteClicked

                    afterFailure : MealShow.Model
                    afterFailure =
                        step (MealShow.DeleteCompleted (Err Client.NetworkError)) deleting
                in
                { failedState = toScreen afterFailure |> .delete
                , retry = out MealShow.ConfirmDeleteClicked afterFailure
                , unauthorized = out (MealShow.DeleteCompleted (Err unauthorized)) deleting
                }
                    |> Expect.equal
                        { failedState = Just (DeleteFailed networkErrorMessage)
                        , retry = MealShow.RequestDeleteMeal "meal-1"
                        , unauthorized = MealShow.SessionExpired
                        }
        , test "the edit action navigates to the meal edit route" <|
            \_ ->
                out MealShow.EditClicked loadedMealModel
                    |> Expect.equal (MealShow.Navigate (MealEdit "meal-1"))
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , units : Maybe (List UnitItem)
    , nutrition : String
    , nutrients : Maybe (List NutrientAmount)
    , amount : Maybe String
    , unit : Maybe String
    , delete : Maybe DeleteState
    , error : Maybe String
    }


toScreen : MealShow.Model -> Screen
toScreen model =
    case model of
        MealShow.Loading loading ->
            { phase = "loading"
            , units = Just loading.units
            , nutrition = statusOf loading.nutrition
            , nutrients = nutrientsOf loading.nutrition
            , amount = Just (nutritionInput loading.nutrition).amount
            , unit = Just (nutritionInput loading.nutrition).unit
            , delete = Nothing
            , error = Nothing
            }

        MealShow.Loaded loaded ->
            { phase = "loaded"
            , units = Just loaded.units
            , nutrition = statusOf loaded.nutrition
            , nutrients = nutrientsOf loaded.nutrition
            , amount = Just (nutritionInput loaded.nutrition).amount
            , unit = Just (nutritionInput loaded.nutrition).unit
            , delete = Just loaded.delete
            , error = Nothing
            }

        MealShow.LoadFailed failed ->
            { phase = "failed"
            , units = Nothing
            , nutrition = "none"
            , nutrients = Nothing
            , amount = Nothing
            , unit = Nothing
            , delete = Nothing
            , error = Just failed.message
            }


statusOf : NutritionState -> String
statusOf nutrition =
    case nutrition of
        NutritionLoading _ ->
            "loading"

        NutritionLoaded _ _ ->
            "loaded"

        NutritionFailed _ _ ->
            "failed"

        NutritionUnavailable _ ->
            "unavailable"


nutrientsOf : NutritionState -> Maybe (List NutrientAmount)
nutrientsOf nutrition =
    case nutrition of
        NutritionLoaded _ nutrients ->
            Just nutrients

        _ ->
            Nothing


nameFor : String -> MealShow.Model -> String
nameFor productId model =
    case model of
        MealShow.Loaded loaded ->
            ItemNameLookup.nameFor "" (ItemNameLookup.productRef productId) loaded.productNames

        _ ->
            ""


step : MealShow.Msg -> MealShow.Model -> MealShow.Model
step msg model =
    first (MealShow.update msg model)


out : MealShow.Msg -> MealShow.Model -> MealShow.OutMsg
out msg model =
    third (MealShow.update msg model)


loadedMealModel : MealShow.Model
loadedMealModel =
    MealShow.init "meal-1"
        |> Tuple.first
        |> step (MealShow.MealLoaded "meal-1" (Ok meal))
        |> step (MealShow.UnitsLoaded (Ok { items = [ gram ] }))


nutritionLoadedModel : MealShow.Model
nutritionLoadedModel =
    step
        (MealShow.NutrientPreviewLoaded "meal-1" (Ok (previewFor "100" "g" [ nutrient ])))
        loadedMealModel


previewFor : String -> String -> List NutrientAmount -> MealNutritionResponse
previewFor amount unit nutrients =
    { mealId = "meal-1"
    , quantity = { amount = amount, unit = unit }
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = nutrients
    }


applyPreview :
    String
    -> String
    -> List NutrientAmount
    -> MealShow.Model
    -> MealShow.Model
applyPreview amount unit nutrients model =
    step
        (MealShow.NutrientPreviewLoaded "meal-1" (Ok (previewFor amount unit nutrients)))
        model


meal : Meal
meal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , nutritionSummary = Nothing
    , components =
        [ { id = "component-1"
          , item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "100", unit = "g" }
          , nutritionSummary = Nothing
          }
        ]
    , createdAt = "now"
    , updatedAt = "now"
    }


twoProductMeal : Meal
twoProductMeal =
    { meal
        | components =
            meal.components
                ++ [ { id = "component-2"
                     , item = { itemType = ItemRef.Product, id = "food-2" }
                     , quantity = { amount = "50", unit = "g" }
                     , nutritionSummary = Nothing
                     }
                   ]
    }


repeatedProductMeal : Meal
repeatedProductMeal =
    { meal
        | components =
            meal.components
                ++ [ { id = "component-2"
                     , item = { itemType = ItemRef.Product, id = "food-1" }
                     , quantity = { amount = "50", unit = "g" }
                     , nutritionSummary = Nothing
                     }
                   , { id = "component-meal"
                     , item = { itemType = ItemRef.Meal, id = "meal-child" }
                     , quantity = { amount = "1", unit = "serving" }
                     , nutritionSummary = Nothing
                     }
                   ]
    }


product : ProductDetail
product =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


banana : ProductDetail
banana =
    { product | id = "food-2", name = "Banana" }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


scaledNutrient : NutrientAmount
scaledNutrient =
    { code = "ENERGY_KCAL", amount = "180", unit = "kcal" }


servingNutrient : NutrientAmount
servingNutrient =
    { code = "ENERGY_KCAL", amount = "90", unit = "kcal" }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


fallbackGram : UnitItem
fallbackGram =
    { code = "g", name = "g", kind = "mass" }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
