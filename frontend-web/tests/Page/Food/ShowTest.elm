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
        [ test "loading composes food, units, and the last-used default into a ready form" <|
            \_ ->
                let
                    ( model, initial ) =
                        FoodShow.init "food-1" (Just sampleDate) (Just Lunch) Nothing

                    loaded : FoodShow.Model
                    loaded =
                        model
                            |> step
                                (FoodShow.LastUsedLoaded "food-1"
                                    (Ok { items = [ recentItem ] })
                                )
                            |> step (FoodShow.FoodLoaded "food-1" (Ok food))
                            |> step (FoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                in
                { initial = initial
                , phase = toScreen loaded |> .phase
                , amount = toScreen loaded |> .amount
                , unit = toScreen loaded |> .unit
                }
                    |> Expect.equal
                        { initial = FoodShow.RequestInitialData "food-1"
                        , phase = "loaded"
                        , amount = Just "5"
                        , unit = Just "g"
                        }
        , test "a response for another product is ignored and a failed load stays failed" <|
            \_ ->
                let
                    afterOtherProduct : FoodShow.Model
                    afterOtherProduct =
                        step (FoodShow.FoodLoaded "other" (Ok food)) loadedModel

                    afterLateSuccess : FoodShow.Model
                    afterLateSuccess =
                        step (FoodShow.FoodLoaded "food-1" (Ok food)) failedModel
                in
                { otherPhase = toScreen afterOtherProduct |> .phase
                , otherAmount = toScreen afterOtherProduct |> .amount
                , failedPhase = toScreen afterLateSuccess |> .phase
                , failedError = toScreen afterLateSuccess |> .error
                }
                    |> Expect.equal
                        { otherPhase = "loaded"
                        , otherAmount = Just "2"
                        , failedPhase = "failed"
                        , failedError = Just networkErrorMessage
                        }
        , test "submitting validates the amount and blocks a duplicate while in flight" <|
            \_ ->
                let
                    blank : FoodShow.Model
                    blank =
                        step (FoodShow.FormMsg (FoodLogForm.AmountChanged " ")) loadedModel

                    submitting : FoodShow.Model
                    submitting =
                        step FoodShow.SubmitClicked loadedModel
                in
                { blankRequest = out FoodShow.SubmitClicked blank
                , blankError = toScreen (step FoodShow.SubmitClicked blank) |> .submitError
                , validRequest = out FoodShow.SubmitClicked loadedModel
                , inFlight = toScreen submitting |> .submit
                , duplicateRequest = out FoodShow.SubmitClicked submitting
                }
                    |> Expect.equal
                        { blankRequest = FoodShow.NoOp
                        , blankError = Just "Amount is required."
                        , validRequest = FoodShow.RequestLocalContext
                        , inFlight = Just FoodLogForm.SubmitSubmitting
                        , duplicateRequest = FoodShow.NoOp
                        }
        , test "local context builds the log request from the diary date or the device date" <|
            \_ ->
                let
                    context : { date : LocalDate, timezone : String }
                    context =
                        { date = sampleDateFromString "2026-06-04", timezone = "Asia/Kolkata" }

                    requestFor : FoodShow.Model -> FoodShow.OutMsg
                    requestFor model =
                        out (FoodShow.LocalContextReceived context)
                            (step FoodShow.SubmitClicked model)
                in
                { selectedDate = requestFor loadedModel
                , deviceDate = requestFor loadedWithoutDate
                }
                    |> Expect.equal
                        { selectedDate = createLogRequest (sampleDateFromString "2026-05-29")
                        , deviceDate = createLogRequest (sampleDateFromString "2026-06-04")
                        }
        , test "a completed log reports the created log with its contextual search route" <|
            \_ ->
                out (FoodShow.LogCompleted (Ok log)) savingModel
                    |> Expect.equal
                        (FoodShow.LogCreated log
                            (FoodSearch (Just sampleDate) (Just Lunch))
                        )
        , test "a failed log keeps the current form and surfaces the request error" <|
            \_ ->
                let
                    afterFailure : FoodShow.Model
                    afterFailure =
                        step (FoodShow.LogCompleted (Err Client.NetworkError)) savingModel
                in
                { request = out (FoodShow.LogCompleted (Err Client.NetworkError)) savingModel
                , amount = toScreen afterFailure |> .amount
                , submit = toScreen afterFailure |> .submit
                }
                    |> Expect.equal
                        { request = FoodShow.NoOp
                        , amount = Just "2"
                        , submit =
                            Just
                                (FoodLogForm.SubmitFailed
                                    (FoodLogForm.RequestFailed networkErrorMessage)
                                )
                        }
        , test "a units load failure reports the page error and unauthorized expires the session" <|
            \_ ->
                let
                    afterFailure : FoodShow.Model
                    afterFailure =
                        step (FoodShow.UnitsLoaded (Err Client.NetworkError)) emptyModel
                in
                { phase = toScreen afterFailure |> .phase
                , error = toScreen afterFailure |> .error
                , unauthorized =
                    out
                        (FoodShow.UnitsLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        emptyModel
                }
                    |> Expect.equal
                        { phase = "failed"
                        , error = Just networkErrorMessage
                        , unauthorized = FoodShow.SessionExpired
                        }
        , test "display nutrients fall back to per-100g when the serving conversion is unknown" <|
            \_ ->
                FoodShow.foodNutrientsForDisplay foodWithNutrition { form | unit = "cup" }
                    |> Expect.equal
                        [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , amount : Maybe String
    , unit : Maybe String
    , submit : Maybe FoodLogForm.SubmitState
    , submitError : Maybe String
    , error : Maybe String
    }


toScreen : FoodShow.Model -> Screen
toScreen model =
    case model of
        FoodShow.Loaded loaded ->
            { phase = "loaded"
            , amount = Just loaded.form.amount
            , unit = Just loaded.form.unit
            , submit = Just loaded.form.submitState
            , submitError = formError loaded.form
            , error = Nothing
            }

        FoodShow.Loading _ ->
            { phase = "loading"
            , amount = Nothing
            , unit = Nothing
            , submit = Nothing
            , submitError = Nothing
            , error = Nothing
            }

        FoodShow.LoadFailed failed ->
            { phase = "failed"
            , amount = Nothing
            , unit = Nothing
            , submit = Nothing
            , submitError = Nothing
            , error = Just failed.message
            }


formError : FoodLogForm.Model -> Maybe String
formError current =
    case current.submitState of
        FoodLogForm.SubmitFailed failure ->
            Just (FoodLogForm.submitFailureMessage failure)

        _ ->
            Nothing


createLogRequest : LocalDate -> FoodShow.OutMsg
createLogRequest logDate =
    FoodShow.RequestCreateLog
        { logDate = logDate
        , deviceTimezone = Just "Asia/Kolkata"
        , mealSlot = Just Lunch
        , item = { itemType = ItemRef.Product, id = "food-1" }
        , quantity = { amount = "2", unit = "serving" }
        , notes = Nothing
        }


step : FoodShow.Msg -> FoodShow.Model -> FoodShow.Model
step msg model =
    first (FoodShow.update msg model)


out : FoodShow.Msg -> FoodShow.Model -> FoodShow.OutMsg
out msg model =
    third (FoodShow.update msg model)


emptyModel : FoodShow.Model
emptyModel =
    FoodShow.init "food-1" (Just sampleDate) (Just Lunch) Nothing
        |> Tuple.first


failedModel : FoodShow.Model
failedModel =
    step (FoodShow.UnitsLoaded (Err Client.NetworkError)) emptyModel


initialLoad : Maybe LocalDate -> Maybe MealSlot -> FoodShow.Model
initialLoad logDate mealSlot =
    FoodShow.init "food-1" logDate mealSlot Nothing
        |> Tuple.first


loadedModel : FoodShow.Model
loadedModel =
    initialLoad (Just sampleDate) (Just Lunch)
        |> step (FoodShow.FoodLoaded "food-1" (Ok food))
        |> step (FoodShow.UnitsLoaded (Ok { items = [ gram ] }))


loadedWithoutDate : FoodShow.Model
loadedWithoutDate =
    initialLoad Nothing (Just Lunch)
        |> step (FoodShow.FoodLoaded "food-1" (Ok food))
        |> step (FoodShow.UnitsLoaded (Ok { items = [ gram ] }))


savingModel : FoodShow.Model
savingModel =
    step FoodShow.SubmitClicked loadedModel


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
    , mealSlot = Just Lunch
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
