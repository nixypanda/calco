module Page.FoodLog.EntryTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.FoodLog.Entry as FoodLogEntry
import Test exposing (Test, describe, test)
import View.DeleteModal exposing (DeleteState(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.FoodLog.Entry"
        [ test "loading a product log requests its detail and completes once units arrive" <|
            \_ ->
                let
                    ( loading, initial ) =
                        FoodLogEntry.init "log-1"

                    unitsOnly : FoodLogEntry.Model
                    unitsOnly =
                        step (FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] })) loading

                    completed : FoodLogEntry.Model
                    completed =
                        step (FoodLogEntry.LogLoaded "log-1" (Ok productLog)) unitsOnly
                in
                { initial = initial
                , unitsPhase = toScreen unitsOnly |> .phase
                , detailRequest = out (FoodLogEntry.LogLoaded "log-1" (Ok productLog)) unitsOnly
                , completedPhase = toScreen completed |> .phase
                , amount = toScreen completed |> .amount
                }
                    |> Expect.equal
                        { initial = FoodLogEntry.RequestInitialData "log-1"
                        , unitsPhase = "loading"
                        , detailRequest = FoodLogEntry.RequestProductDetail "food-1"
                        , completedPhase = "loaded"
                        , amount = Just "2"
                        }
        , test "a response for another log is ignored and a failed load surfaces the page error" <|
            \_ ->
                let
                    ( loading, _ ) =
                        FoodLogEntry.init "log-1"

                    afterOther : FoodLogEntry.Model
                    afterOther =
                        step (FoodLogEntry.LogLoaded "other" (Ok productLog)) loading

                    afterFailure : FoodLogEntry.Model
                    afterFailure =
                        step (FoodLogEntry.LogLoaded "log-1" (Err Client.NetworkError)) loading
                in
                { otherPhase = toScreen afterOther |> .phase
                , failedPhase = toScreen afterFailure |> .phase
                , error = toScreen afterFailure |> .error
                }
                    |> Expect.equal
                        { otherPhase = "loading"
                        , failedPhase = "failed"
                        , error = Just networkErrorMessage
                        }
        , test "product nutrients follow the edit form quantity" <|
            \_ ->
                FoodLogEntry.nutrientsForDisplay (Just foodWithNutrition) productLog form
                    |> Expect.equal
                        [ { code = "ENERGY_KCAL"
                          , amount = "120"
                          , unit = "kcal"
                          }
                        ]
        , test "meal nutrients scale the saved snapshot and hold when units change" <|
            \_ ->
                let
                    scaled : FoodLogForm.Model
                    scaled =
                        { form | amount = "3" }

                    scaledInGrams : FoodLogForm.Model
                    scaledInGrams =
                        { form | amount = "3", unit = "g" }
                in
                { scaled =
                    FoodLogEntry.nutrientsForDisplay Nothing logWithNutrients scaled
                , heldWhenUnitChanges =
                    FoodLogEntry.nutrientsForDisplay Nothing logWithNutrients scaledInGrams
                }
                    |> Expect.equal
                        { scaled =
                            [ { code = "ENERGY_KCAL"
                              , amount = "180"
                              , unit = "kcal"
                              }
                            ]
                        , heldWhenUnitChanges =
                            [ { code = "ENERGY_KCAL"
                              , amount = "120"
                              , unit = "kcal"
                              }
                            ]
                        }
        , test "submitting an edit sends the update payload and reports the affected diary date" <|
            \_ ->
                let
                    afterSubmit : FoodLogEntry.Model
                    afterSubmit =
                        step FoodLogEntry.SubmitClicked loadedModel
                in
                { request = out FoodLogEntry.SubmitClicked loadedModel
                , phase = toScreen afterSubmit |> .phase
                , success = out (FoodLogEntry.UpdateCompleted (Ok updatedLog)) afterSubmit
                }
                    |> Expect.equal
                        { request =
                            FoodLogEntry.RequestUpdateLog "log-1"
                                { mealSlot = Just Lunch
                                , quantity = { amount = "2", unit = "serving" }
                                , notes = Just "Good"
                                }
                        , phase = "loaded"
                        , success = FoodLogEntry.LogUpdated updatedLog.logDate
                        }
        , test "a failed update keeps the form and shows the request error" <|
            \_ ->
                let
                    afterFailure : FoodLogEntry.Model
                    afterFailure =
                        step
                            (FoodLogEntry.UpdateCompleted (Err Client.NetworkError))
                            savingModel
                in
                { request =
                    out (FoodLogEntry.UpdateCompleted (Err Client.NetworkError)) savingModel
                , phase = toScreen afterFailure |> .phase
                , amount = toScreen afterFailure |> .amount
                , submitError = toScreen afterFailure |> .submitError
                }
                    |> Expect.equal
                        { request = FoodLogEntry.NoOp
                        , phase = "loaded"
                        , amount = Just "4"
                        , submitError = Just networkErrorMessage
                        }
        , test "deleting a log confirms, requests, and reports success with its diary date" <|
            \_ ->
                let
                    confirming : FoodLogEntry.Model
                    confirming =
                        step FoodLogEntry.DeleteClicked loadedModel

                    deleting : FoodLogEntry.Model
                    deleting =
                        step FoodLogEntry.ConfirmDeleteClicked confirming
                in
                { confirm = toScreen confirming |> .delete
                , request = out FoodLogEntry.ConfirmDeleteClicked confirming
                , phase = toScreen deleting |> .phase
                , deleted = out (FoodLogEntry.DeleteCompleted (Ok ())) deleting
                }
                    |> Expect.equal
                        { confirm = Just DeleteConfirming
                        , request = FoodLogEntry.RequestDeleteLog "log-1"
                        , phase = "loaded"
                        , deleted =
                            FoodLogEntry.LogDeleted productLog.logDate (DiaryDay Nothing Nothing)
                        }
        , test "a failed delete keeps the modal open and retries the deletion" <|
            \_ ->
                let
                    deleting : FoodLogEntry.Model
                    deleting =
                        loadedModel
                            |> step FoodLogEntry.DeleteClicked
                            |> step FoodLogEntry.ConfirmDeleteClicked

                    afterFailure : FoodLogEntry.Model
                    afterFailure =
                        step
                            (FoodLogEntry.DeleteCompleted (Err Client.NetworkError))
                            deleting
                in
                { failedState = toScreen afterFailure |> .delete
                , retry = out FoodLogEntry.ConfirmDeleteClicked afterFailure
                }
                    |> Expect.equal
                        { failedState = Just (DeleteFailed networkErrorMessage)
                        , retry = FoodLogEntry.RequestDeleteLog "log-1"
                        }
        , test "an unauthorized delete expires the session" <|
            \_ ->
                loadedModel
                    |> step FoodLogEntry.DeleteClicked
                    |> step FoodLogEntry.ConfirmDeleteClicked
                    |> out
                        (FoodLogEntry.DeleteCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> Expect.equal FoodLogEntry.SessionExpired
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , amount : Maybe String
    , unit : Maybe String
    , submit : Maybe FoodLogForm.SubmitState
    , submitError : Maybe String
    , delete : Maybe DeleteState
    , error : Maybe String
    }


toScreen : FoodLogEntry.Model -> Screen
toScreen model =
    case model of
        FoodLogEntry.Loaded loaded ->
            { phase = "loaded"
            , amount = Just loaded.form.amount
            , unit = Just loaded.form.unit
            , submit = Just loaded.form.submitState
            , submitError = formError loaded.form
            , delete = Just loaded.delete
            , error = Nothing
            }

        FoodLogEntry.Loading _ ->
            { phase = "loading"
            , amount = Nothing
            , unit = Nothing
            , submit = Nothing
            , submitError = Nothing
            , delete = Nothing
            , error = Nothing
            }

        FoodLogEntry.LoadFailed failed ->
            { phase = "failed"
            , amount = Nothing
            , unit = Nothing
            , submit = Nothing
            , submitError = Nothing
            , delete = Nothing
            , error = Just failed.error
            }


formError : FoodLogForm.Model -> Maybe String
formError current =
    case current.submitState of
        FoodLogForm.SubmitFailed failure ->
            Just (FoodLogForm.submitFailureMessage failure)

        _ ->
            Nothing


step : FoodLogEntry.Msg -> FoodLogEntry.Model -> FoodLogEntry.Model
step msg model =
    first (FoodLogEntry.update msg model)


out : FoodLogEntry.Msg -> FoodLogEntry.Model -> FoodLogEntry.OutMsg
out msg model =
    third (FoodLogEntry.update msg model)


loadingModel : FoodLogEntry.Model
loadingModel =
    FoodLogEntry.init "log-1" |> Tuple.first


loadedModel : FoodLogEntry.Model
loadedModel =
    loadingModel
        |> step (FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] }))
        |> step (FoodLogEntry.LogLoaded "log-1" (Ok productLog))


savingModel : FoodLogEntry.Model
savingModel =
    loadedModel
        |> step (FoodLogEntry.FormMsg (FoodLogForm.AmountChanged "4"))
        |> step FoodLogEntry.SubmitClicked


form : FoodLogForm.Model
form =
    FoodLogForm.initLogFormFromLog productLog


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
