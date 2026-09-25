module Page.Food.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Logs as Logs
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Food.Show as FoodShow
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.Food.Show"
        [ test "units load unauthorized expires session" <|
            \_ ->
                FoodShow.update
                    (FoodShow.UnitsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    emptyModel
                    |> third
                    |> Expect.equal FoodShow.SessionExpired
        , test "load success is ignored after load failed" <|
            \_ ->
                FoodShow.update
                    (FoodShow.FoodLoaded "food-1" (Ok food))
                    (FoodShow.LoadFailed "old")
                    |> first
                    |> Expect.equal (FoodShow.LoadFailed "old")
        , test "food reload refreshes loaded form and clears request state" <|
            \_ ->
                FoodShow.update
                    (FoodShow.FoodLoaded "food-1" (Ok { food | defaultQuantity = Just "3" }))
                    savingModel
                    |> first
                    |> (\model ->
                            ( formOf model |> Maybe.map .amount
                            , formOf model |> Maybe.map .submitState
                            )
                       )
                    |> Expect.equal ( Just "3", Just FoodLogForm.SubmitIdle )
        , test "last used default is stored while loading and applied after load completes" <|
            \_ ->
                FoodShow.update
                    (FoodShow.LastUsedLoaded "food-1" (Ok { items = [ recentItem ] }))
                    emptyModel
                    |> first
                    |> FoodShow.update (FoodShow.FoodLoaded "food-1" (Ok food))
                    |> first
                    |> FoodShow.update (FoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> formOf
                    |> Maybe.map (\current -> ( current.amount, current.unit ))
                    |> Expect.equal (Just ( "5", "g" ))
        , test "a load response for another product is ignored" <|
            \_ ->
                FoodShow.update (FoodShow.FoodLoaded "other" (Ok food)) loadedModel
                    |> first
                    |> Expect.equal loadedModel
        , test "display nutrients fall back when serving conversion is unknown" <|
            \_ ->
                FoodShow.foodNutrientsForDisplay
                    foodWithNutrition
                    { form | unit = "cup" }
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        , test "submit requests local context after validation" <|
            \_ ->
                FoodShow.update FoodShow.SubmitClicked loadedModel
                    |> third
                    |> Expect.equal FoodShow.RequestLocalContext
        , test "submit with blank amount stores validation error" <|
            \_ ->
                FoodShow.update
                    FoodShow.SubmitClicked
                    (loadedWithForm { form | amount = " " })
                    |> first
                    |> formOf
                    |> Maybe.andThen submitFailureMessage
                    |> Expect.equal (Just "Amount is required.")
        , test "submit is ignored while request is in flight" <|
            \_ ->
                FoodShow.update FoodShow.SubmitClicked contextReadyModel
                    |> third
                    |> Expect.equal FoodShow.NoOp
        , test "local context uses selected diary date for log request" <|
            \_ ->
                FoodShow.update
                    (FoodShow.LocalContextReceived
                        { date = "2026-06-04"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    contextReadyModel
                    |> third
                    |> Expect.equal
                        (FoodShow.RequestCreateLog
                            { logDate = sampleDate
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "local context without selected diary date falls back to device date" <|
            \_ ->
                FoodShow.update
                    (FoodShow.LocalContextReceived
                        { date = "2026-06-04"
                        , timezone = "Asia/Kolkata"
                        }
                    )
                    contextReadyWithoutDateModel
                    |> third
                    |> Expect.equal
                        (FoodShow.RequestCreateLog
                            { logDate = sampleDateFromString "2026-06-04"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "bad device date fails when no diary date is selected" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        FoodShow.update
                            (FoodShow.LocalContextReceived
                                { date = "not-a-date"
                                , timezone = "Asia/Kolkata"
                                }
                            )
                            contextReadyWithoutDateModel

                    formError : Maybe String
                    formError =
                        formOf model
                            |> Maybe.andThen submitFailureMessage
                in
                ( outMsg
                , formError
                )
                    |> Expect.equal
                        ( FoodShow.NoOp
                        , Just "Could not read device date."
                        )
        , test "log success reports the created log and contextual search" <|
            \_ ->
                FoodShow.update (FoodShow.LogCompleted (Ok log)) savingModel
                    |> third
                    |> Expect.equal
                        (FoodShow.LogCreated log
                            (FoodSearch (Just "2026-05-29") (Just Lunch))
                        )
        , test "log failure keeps form state and stores error" <|
            \_ ->
                let
                    ( model, _, _ ) =
                        FoodShow.update
                            (FoodShow.LogCompleted (Err Client.NetworkError))
                            savingModel
                in
                Maybe.map (\current -> ( current.amount, current.submitState )) (formOf model)
                    |> Expect.equal
                        (Just
                            ( "2"
                            , FoodLogForm.SubmitFailed
                                (FoodLogForm.RequestFailed networkErrorMessage)
                            )
                        )
        ]


emptyModel : FoodShow.Model
emptyModel =
    FoodShow.Loading
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = Nothing
        , units = Nothing
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


loadedModel : FoodShow.Model
loadedModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = form
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


contextReadyModel : FoodShow.Model
contextReadyModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = { form | submitState = FoodLogForm.SubmitSubmitting }
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


contextReadyWithoutDateModel : FoodShow.Model
contextReadyWithoutDateModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Nothing
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = { form | submitState = FoodLogForm.SubmitSubmitting }
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


savingModel : FoodShow.Model
savingModel =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = { form | submitState = FoodLogForm.SubmitSubmitting }
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


loadedWithForm : FoodLogForm.Model -> FoodShow.Model
loadedWithForm nextForm =
    FoodShow.Loaded
        { productId = "food-1"
        , logDate = Just "2026-05-29"
        , mealSlot = Just Lunch
        , food = food
        , units = [ gram ]
        , form = nextForm
        , lastUsedDefault = Nothing
        , lookupNote = Nothing
        }


formOf : FoodShow.Model -> Maybe FoodLogForm.Model
formOf model =
    case model of
        FoodShow.Loaded loaded ->
            Just loaded.form

        _ ->
            Nothing


submitFailureMessage : FoodLogForm.Model -> Maybe String
submitFailureMessage current =
    case current.submitState of
        FoodLogForm.SubmitFailed failure ->
            Just (FoodLogForm.submitFailureMessage failure)

        _ ->
            Nothing


form : FoodLogForm.Model
form =
    FoodLogForm.initLogFormFromFood (Just Lunch) food


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
    , nutritionSummary = { per100g = Nutrition.emptySummary }
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
            [ { unit = "serving"
              , gramsPerUnit = "50"
              }
            ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


recentItem : Logs.RecentItem
recentItem =
    { item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Nothing }
    , lastUsedDate = sampleDate
    , mealSlot = Just "lunch"
    , quantity = { amount = "5", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , topQuantities = [ { quantity = { amount = "5", unit = "g" }, logCount = 2 } ]
    }


log : FoodLog
log =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }


sampleDate : LocalDate
sampleDate =
    sampleDateFromString "2026-05-29"


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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
