module Page.FoodLog.EntryTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.FoodLog.Entry as FoodLogEntry
import Test exposing (Test, describe, test)
import Page.FoodLog.Form as FoodLogForm


tests : Test
tests =
    describe "Page.FoodLog.Entry"
        [ test "init requests log and units" <|
            \_ ->
                FoodLogEntry.init "log-1"
                    |> Tuple.second
                    |> Expect.equal (FoodLogEntry.RequestInitialData "log-1")
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
                FoodLogEntry.update
                    (FoodLogEntry.LogLoaded (Ok productLog))
                    emptyModel
                    |> third
                    |> Expect.equal
                        (FoodLogEntry.RequestProductDetail "food-1")
        , test "meal log requests meal name" <|
            \_ ->
                FoodLogEntry.update
                    (FoodLogEntry.LogLoaded (Ok mealLog))
                    emptyModel
                    |> third
                    |> Expect.equal (FoodLogEntry.RequestMealName "meal-1")
        , test "product detail success stores product and item name" <|
            \_ ->
                FoodLogEntry.update
                    (FoodLogEntry.ProductDetailLoaded (Ok food))
                    loadedModel
                    |> first
                    |> loadedProductSummary
                    |> Expect.equal ( Just "food-1", "Apple" )
        , test "product display nutrients follow the edit form quantity" <|
            \_ ->
                FoodLogEntry.nutrientsForDisplay
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
                FoodLogEntry.nutrientsForDisplay
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
                FoodLogEntry.nutrientsForDisplay
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
                FoodLogEntry.update
                    (FoodLogEntry.MealNameLoaded
                        (Ok { id = "meal-1", name = "Lunch bowl" })
                    )
                    mealLoadedModel
                    |> first
                    |> loadedItemTitle
                    |> Expect.equal "Lunch bowl"
        , test "submit emits update payload" <|
            \_ ->
                FoodLogEntry.update FoodLogEntry.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal
                        (FoodLogEntry.RequestUpdateLog
                            "log-1"
                            { mealSlot = Just "lunch"
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Just "Good"
                            }
                        )
        , test "update success replaces the current log" <|
            \_ ->
                FoodLogEntry.update
                    (FoodLogEntry.UpdateCompleted (Ok updatedLog))
                    loadedModel
                    |> first
                    |> loadedLogQuantity
                    |> Expect.equal (Just { amount = "3", unit = "g" })
        , test "update failure preserves current log and form state" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodLogEntry.update
                            (FoodLogEntry.UpdateCompleted
                                (Err Client.NetworkError)
                            )
                            savingModel
                in
                loadedFailureSummary model
                    |> Expect.equal
                        (Just
                            { logId = "log-1"
                            , amount = "4"
                            , request = FoodLogEntry.Idle
                            , error = Just "Network error"
                            }
                        )
        , test "delete success navigates home" <|
            \_ ->
                FoodLogEntry.update
                    (FoodLogEntry.DeleteCompleted (Ok ()))
                    loadedModel
                    |> third
                    |> Expect.equal (FoodLogEntry.Navigate (DiaryDay Nothing))
        , test "delete failure keeps page open and stores error" <|
            \_ ->
                FoodLogEntry.update
                    (FoodLogEntry.DeleteCompleted (Err Client.NetworkError))
                    deletingModel
                    |> first
                    |> loadedDeleteFailureSummary
                    |> Expect.equal
                        (Just
                            { logId = "log-1"
                            , request = FoodLogEntry.Idle
                            , error = Just "Network error"
                            }
                        )
        ]


emptyModel : FoodLogEntry.Model
emptyModel =
    FoodLogEntry.Loading
        { logId = "log-1"
        , log = Nothing
        , units = Nothing
        }


loadedModel : FoodLogEntry.Model
loadedModel =
    FoodLogEntry.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogEntry.ProductItem
                (FoodLogEntry.DetailLoading productLog.item)
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodLogEntry.Idle
        }


savingModel : FoodLogEntry.Model
savingModel =
    FoodLogEntry.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogEntry.ProductItem
                (FoodLogEntry.DetailLoading productLog.item)
        , units = [ gram ]
        , form = { form | amount = "4", submitting = True }
        , error = Nothing
        , request = FoodLogEntry.Saving
        }


deletingModel : FoodLogEntry.Model
deletingModel =
    FoodLogEntry.Loaded
        { logId = "log-1"
        , log = productLog
        , item =
            FoodLogEntry.ProductItem
                (FoodLogEntry.DetailLoading productLog.item)
        , units = [ gram ]
        , form = form
        , error = Nothing
        , request = FoodLogEntry.Deleting
        }


mealLoadedModel : FoodLogEntry.Model
mealLoadedModel =
    FoodLogEntry.Loaded
        { logId = "log-1"
        , log = mealLog
        , item = FoodLogEntry.MealItem (FoodLogEntry.DetailLoading mealLog.item)
        , units = [ gram ]
        , form = FoodLogForm.initLogFormFromLog mealLog
        , error = Nothing
        , request = FoodLogEntry.Idle
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
        { itemType = ItemRef.Product
        , id = "food-1"
        , name = "Apple"
        , brand = Just "Local"
        }
    , quantity = { amount = "2", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
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
            { itemType = ItemRef.Meal
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
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
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


loadedForm : FoodLogEntry.Model -> Maybe FoodLogForm.Model
loadedForm model =
    case model of
        FoodLogEntry.Loaded loaded ->
            Just loaded.form

        _ ->
            Nothing


loadedProductSummary : FoodLogEntry.Model -> ( Maybe String, String )
loadedProductSummary model =
    case model of
        FoodLogEntry.Loaded loaded ->
            case loaded.item of
                FoodLogEntry.ProductItem (FoodLogEntry.DetailLoaded loadedFood) ->
                    ( Just loadedFood.id, loadedFood.name )

                _ ->
                    ( Nothing, "Loading..." )

        _ ->
            ( Nothing, "Loading..." )


loadedItemTitle : FoodLogEntry.Model -> String
loadedItemTitle model =
    case model of
        FoodLogEntry.Loaded loaded ->
            case loaded.item of
                FoodLogEntry.MealItem (FoodLogEntry.DetailLoaded meal) ->
                    meal.name

                FoodLogEntry.MealItem (FoodLogEntry.DetailLoading _) ->
                    "Loading meal..."

                FoodLogEntry.MealItem (FoodLogEntry.DetailUnavailable item) ->
                    item.name

                _ ->
                    "Loading..."

        _ ->
            "Loading..."


loadedLogQuantity :
    FoodLogEntry.Model
    -> Maybe { amount : String, unit : String }
loadedLogQuantity model =
    case model of
        FoodLogEntry.Loaded loaded ->
            Just loaded.log.quantity

        _ ->
            Nothing


loadedFailureSummary :
    FoodLogEntry.Model
    ->
        Maybe
            { logId : String
            , amount : String
            , request : FoodLogEntry.RequestState
            , error : Maybe String
            }
loadedFailureSummary model =
    case model of
        FoodLogEntry.Loaded loaded ->
            Just
                { logId = loaded.log.id
                , amount = loaded.form.amount
                , request = loaded.request
                , error = loaded.error
                }

        _ ->
            Nothing


loadedDeleteFailureSummary :
    FoodLogEntry.Model
    ->
        Maybe
            { logId : String
            , request : FoodLogEntry.RequestState
            , error : Maybe String
            }
loadedDeleteFailureSummary model =
    case model of
        FoodLogEntry.Loaded loaded ->
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
