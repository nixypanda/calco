module FoodLogDetailTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
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
                loadedModel
                    |> loadedForm
                    |> Maybe.map formSummary
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
                FoodLogDetail.update
                    (FoodLogDetail.LogLoaded (Ok productLog))
                    emptyModel
                    |> third
                    |> Expect.equal
                        (FoodLogDetail.RequestProductDetail "food-1")
        , test "meal log requests meal name" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.LogLoaded (Ok mealLog))
                    emptyModel
                    |> third
                    |> Expect.equal (FoodLogDetail.RequestMealName "meal-1")
        , test "product detail success stores product and item name" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.ProductDetailLoaded (Ok food))
                    loadedModel
                    |> first
                    |> loadedProductSummary
                    |> Expect.equal ( Just "food-1", "Apple" )
        , test "product display nutrients follow the edit form quantity" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay
                    (Just foodWithNutrition)
                    productLog
                    form
                    |> Expect.equal
                        [ { code = "ENERGY_KCAL"
                          , amount = "120"
                          , unit = "kcal"
                          }
                        ]
        , test "meal display nutrients scale saved snapshot" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay
                    Nothing
                    logWithNutrients
                    { form | amount = "3" }
                    |> Expect.equal
                        [ { code = "ENERGY_KCAL"
                          , amount = "180"
                          , unit = "kcal"
                          }
                        ]
        , test "meal display nutrients fall back when units change" <|
            \_ ->
                FoodLogDetail.nutrientsForDisplay
                    Nothing
                    logWithNutrients
                    { form | amount = "3", unit = "g" }
                    |> Expect.equal
                        [ { code = "ENERGY_KCAL"
                          , amount = "120"
                          , unit = "kcal"
                          }
                        ]
        , test "meal name success stores item name" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.MealNameLoaded
                        (Ok { id = "meal-1", name = "Lunch bowl" })
                    )
                    mealLoadedModel
                    |> first
                    |> loadedItemTitle
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
                FoodLogDetail.update
                    (FoodLogDetail.UpdateCompleted (Ok updatedLog))
                    loadedModel
                    |> first
                    |> loadedLogQuantity
                    |> Expect.equal (Just { amount = "3", unit = "g" })
        , test "update failure preserves current log and form state" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodLogDetail.update
                            (FoodLogDetail.UpdateCompleted
                                (Err Client.NetworkError)
                            )
                            savingModel
                in
                loadedFailureSummary model
                    |> Expect.equal
                        (Just
                            { logId = "log-1"
                            , amount = "4"
                            , request = FoodLogDetail.Idle
                            , error = Just "Network error"
                            }
                        )
        , test "delete success navigates home" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.DeleteCompleted (Ok ()))
                    loadedModel
                    |> third
                    |> Expect.equal (FoodLogDetail.Navigate (Diary Nothing))
        , test "delete failure keeps page open and stores error" <|
            \_ ->
                FoodLogDetail.update
                    (FoodLogDetail.DeleteCompleted (Err Client.NetworkError))
                    deletingModel
                    |> first
                    |> loadedDeleteFailureSummary
                    |> Expect.equal
                        (Just
                            { logId = "log-1"
                            , request = FoodLogDetail.Idle
                            , error = Just "Network error"
                            }
                        )
        ]


emptyModel : FoodLogDetail.Model
emptyModel =
    FoodLogDetail.Loading
        { logId = "log-1"
        , log = Nothing
        , units = Nothing
        }


loadedModel : FoodLogDetail.Model
loadedModel =
    FoodLogDetail.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogDetail.ProductItem
                (FoodLogDetail.ProductLoading productLog.item)
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodLogDetail.Idle
        }


savingModel : FoodLogDetail.Model
savingModel =
    FoodLogDetail.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogDetail.ProductItem
                (FoodLogDetail.ProductLoading productLog.item)
        , units = [ gram ]
        , form = { form | amount = "4", submitting = True }
        , error = Nothing
        , request = FoodLogDetail.Saving
        }


deletingModel : FoodLogDetail.Model
deletingModel =
    FoodLogDetail.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogDetail.ProductItem
                (FoodLogDetail.ProductLoading productLog.item)
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodLogDetail.Deleting
        }


mealLoadedModel : FoodLogDetail.Model
mealLoadedModel =
    FoodLogDetail.Loaded
        { logId = "log-1"
        , log = mealLog
        , item = FoodLogDetail.MealItem (FoodLogDetail.MealLoading mealLog.item)
        , units = [ gram ]
        , form = FoodLogForm.initLogFormFromLog mealLog
        , error = Nothing
        , request = FoodLogDetail.Idle
        }


form : FoodLogForm.Model
form =
    FoodLogForm.initLogFormFromLog productLog


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just "lunch"
    , item =
        { itemType = "product"
        , id = "food-1"
        , name = "Apple"
        , brand = Just "Local"
        }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Just "Good"
    }


sampleDate : LocalDate
sampleDate =
    sampleDateFromString "2026-06-04"


sampleDateFromString : String -> LocalDate
sampleDateFromString raw =
    case LocalDate.fromString raw of
        Just d ->
            d

        Nothing ->
            todayFallback


todayFallback : LocalDate
todayFallback =
    case LocalDate.fromParts 1970 1 1 of
        Just d ->
            d

        Nothing ->
            -- Unreachable: 1970-01-01 is always valid.
            sampleDate


mealLog : FoodLog
mealLog =
    { productLog
        | item =
            { itemType = "meal"
            , id = "meal-1"
            , name = "Lunch meal"
            , brand = Nothing
            }
    }


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
        | nutrients =
            [ { code = "ENERGY_KCAL"
              , amount = "120"
              , unit = "kcal"
              }
            ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


formSummary :
    FoodLogForm.Model
    ->
        { amount : String
        , unit : String
        , mealSlot : Maybe MealSlot
        , notes : String
        }
formSummary current =
    { amount = current.amount
    , unit = current.unit
    , mealSlot = current.mealSlot
    , notes = current.notes
    }


loadedForm : FoodLogDetail.Model -> Maybe FoodLogForm.Model
loadedForm model =
    case model of
        FoodLogDetail.Loaded loaded ->
            Just loaded.form

        _ ->
            Nothing


loadedProductSummary : FoodLogDetail.Model -> ( Maybe String, String )
loadedProductSummary model =
    case model of
        FoodLogDetail.Loaded loaded ->
            case loaded.item of
                FoodLogDetail.ProductItem (FoodLogDetail.ProductLoaded loadedFood) ->
                    ( Just loadedFood.id, loadedFood.name )

                _ ->
                    ( Nothing, "Loading..." )

        _ ->
            ( Nothing, "Loading..." )


loadedItemTitle : FoodLogDetail.Model -> String
loadedItemTitle model =
    case model of
        FoodLogDetail.Loaded loaded ->
            case loaded.item of
                FoodLogDetail.MealItem (FoodLogDetail.MealLoaded meal) ->
                    meal.name

                FoodLogDetail.MealItem (FoodLogDetail.MealLoading _) ->
                    "Loading meal..."

                FoodLogDetail.MealItem (FoodLogDetail.MealUnavailable item) ->
                    item.name

                _ ->
                    "Loading..."

        _ ->
            "Loading..."


loadedLogQuantity :
    FoodLogDetail.Model
    -> Maybe { amount : String, unit : String }
loadedLogQuantity model =
    case model of
        FoodLogDetail.Loaded loaded ->
            Just loaded.log.quantity

        _ ->
            Nothing


loadedFailureSummary :
    FoodLogDetail.Model
    ->
        Maybe
            { logId : String
            , amount : String
            , request : FoodLogDetail.RequestState
            , error : Maybe String
            }
loadedFailureSummary model =
    case model of
        FoodLogDetail.Loaded loaded ->
            Just
                { logId = loaded.log.id
                , amount = loaded.form.amount
                , request = loaded.request
                , error = loaded.error
                }

        _ ->
            Nothing


loadedDeleteFailureSummary :
    FoodLogDetail.Model
    ->
        Maybe
            { logId : String
            , request : FoodLogDetail.RequestState
            , error : Maybe String
            }
loadedDeleteFailureSummary model =
    case model of
        FoodLogDetail.Loaded loaded ->
            Just
                { logId = loaded.log.id
                , request = loaded.request
                , error = loaded.error
                }

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
