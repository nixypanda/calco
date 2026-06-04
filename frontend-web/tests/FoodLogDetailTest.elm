module FoodLogDetailTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Page.FoodLog.Detail as FoodLogDetail
import Test exposing (Test, describe, test)
import View.FoodLogForm as FoodLogForm


tests : Test
tests =
    describe "Page.FoodLog.Detail"
        [ test "init requests log and units" <|
            \_ ->
                FoodLogDetail.init "log-1"
                    |> Tuple.second
                    |> Expect.equal (FoodLogDetail.RequestInitialData "log-1")
        , test "load-log success initializes the edit form" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.LogLoaded (Ok productLog)) emptyModel
                    |> first
                    |> .form
                    |> Maybe.map
                        (\current ->
                            { amount = current.amount
                            , unit = current.unit
                            , mealSlot = current.mealSlot
                            , notes = current.notes
                            }
                        )
                    |> Expect.equal
                        (Just
                            { amount = "2"
                            , unit = "serving"
                            , mealSlot = Just Lunch
                            , notes = "Good"
                            }
                        )
        , test "product log requests product name/detail" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.LogLoaded (Ok productLog)) emptyModel
                    |> third
                    |> Expect.equal (FoodLogDetail.RequestProductDetail "food-1")
        , test "meal log requests meal name" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.LogLoaded (Ok mealLog)) emptyModel
                    |> third
                    |> Expect.equal (FoodLogDetail.RequestMealName "meal-1")
        , test "product detail success stores product and item name" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.ProductDetailLoaded (Ok food)) loadedModel
                    |> first
                    |> (\model -> ( Maybe.map .id model.food, model.itemName ))
                    |> Expect.equal ( Just "food-1", "Apple" )
        , test "product display nutrients follow the edit form quantity" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay (Just foodWithNutrition) productLog form
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "meal display nutrients scale saved snapshot when units still match" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay
                    Nothing
                    logWithNutrients
                    { form | amount = "3" }
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "180", unit = "kcal" } ]
        , test "meal display nutrients fall back to saved snapshot when units change" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay
                    Nothing
                    logWithNutrients
                    { form | amount = "3", unit = "g" }
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "meal name success stores item name" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.MealNameLoaded
                        (Ok { id = "meal-1", name = "Lunch bowl" })
                    )
                    loadedModel
                    |> first
                    |> .itemName
                    |> Expect.equal "Lunch bowl"
        , test "submit emits update payload" <|
            \_ ->
                FoodLogDetail.update FoodLogDetail.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal
                        (FoodLogDetail.RequestUpdateLog
                            "log-1"
                            { mealSlot = Just "lunch"
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Just "Good"
                            }
                        )
        , test "update success replaces the current log" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.UpdateCompleted (Ok updatedLog)) loadedModel
                    |> first
                    |> (\model -> Maybe.map .quantity model.log)
                    |> Expect.equal (Just { amount = "3", unit = "g" })
        , test "update failure preserves current log and form state" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodLogDetail.update
                            (FoodLogDetail.UpdateCompleted (Err Client.NetworkError))
                            { loadedModel
                                | form =
                                    Just { form | amount = "4", submitting = True }
                            }
                in
                ( Maybe.map .id model.log
                , Maybe.map
                    (\current -> ( current.amount, current.submitting ))
                    model.form
                , model.error
                )
                    |> Expect.equal ( Just "log-1", Just ( "4", False ), Just "Network error" )
        , test "delete success navigates home" <|
            \_ ->
                FoodLogDetail.update (FoodLogDetail.DeleteCompleted (Ok ())) loadedModel
                    |> third
                    |> Expect.equal (FoodLogDetail.Navigate (Diary Nothing))
        , test "delete failure keeps page open and stores error" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.DeleteCompleted (Err Client.NetworkError))
                    { loadedModel | deleting = True }
                    |> first
                    |> (\model -> ( Maybe.map .id model.log, model.deleting, model.error ))
                    |> Expect.equal ( Just "log-1", False, Just "Network error" )
        ]


emptyModel : FoodLogDetail.Model
emptyModel =
    { logId = "log-1"
    , log = Nothing
    , food = Nothing
    , itemName = ""
    , units = Nothing
    , form = Nothing
    , error = Nothing
    , deleting = False
    }


loadedModel : FoodLogDetail.Model
loadedModel =
    { emptyModel
        | log = Just productLog
        , units = Just [ gram ]
        , form = Just form
    }


form : FoodLogForm.Model
form =
    FoodLogForm.initLogFormFromLog productLog


productLog : FoodLog
productLog =
    { id = "log-1"
    , loggedAt = "2026-06-04T10:00:00+05:30"
    , mealSlot = Just "lunch"
    , item = { itemType = "product", id = "food-1" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Just "Good"
    }


mealLog : FoodLog
mealLog =
    { productLog | item = { itemType = "meal", id = "meal-1" } }


updatedLog : FoodLog
updatedLog =
    { productLog | quantity = { amount = "3", unit = "g" } }


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , defaultQuantity = Just "2"
    , defaultUnit = Just "serving"
    , servingSizeG = Just "100"
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


foodWithNutrition : ProductDetail
foodWithNutrition =
    { food
        | nutrients =
            [ { code = "ENERGY_KCAL"
              , amountPer100g = "120"
              , unit = "kcal"
              , source = Nothing
              , confidence = Nothing
              }
            ]
        , servings =
            [ { label = "Serving"
              , quantity = "1"
              , unit = "serving"
              , grams = "50"
              }
            ]
    }


logWithNutrients : FoodLog
logWithNutrients =
    { productLog
        | nutrients = [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
