module Page.Meal.EditTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Edit as MealEdit
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


submitErrorMessage : Common.SubmitState -> Maybe String
submitErrorMessage state =
    case state of
        Common.SubmitFailed message ->
            Just message

        _ ->
            Nothing


tests : Test
tests =
    describe "Page.Meal.Edit"
        [ test "loading a meal fills the edit form and requests the first product name" <|
            \_ ->
                let
                    ( loading, initial ) =
                        MealEdit.init "meal-1"

                    editing : MealEdit.Model
                    editing =
                        step (MealEdit.MealLoaded "meal-1" (Ok meal)) loading

                    afterOther : MealEdit.Model
                    afterOther =
                        step (MealEdit.MealLoaded "other" (Ok meal)) loading
                in
                { initial = initial
                , request = out (MealEdit.MealLoaded "meal-1" (Ok meal)) loading
                , phase = toScreen editing |> .phase
                , name = toScreen editing |> .name
                , components = toScreen editing |> .components
                , otherPhase = toScreen afterOther |> .phase
                }
                    |> Expect.equal
                        { initial = MealEdit.RequestMeal "meal-1"
                        , request = MealEdit.FormOutMsg (Common.RequestProductName "food-1")
                        , phase = "editing"
                        , name = Just "Lunch"
                        , components = Just [ ( "food-1", "2", "serving" ) ]
                        , otherPhase = "loading"
                        }
        , test "a failed edit load surfaces an error and retrying requests the meal again" <|
            \_ ->
                let
                    failed : MealEdit.Model
                    failed =
                        step
                            (MealEdit.MealLoaded "meal-1" (Err Client.NetworkError))
                            (Tuple.first (MealEdit.init "meal-1"))

                    retrying : MealEdit.Model
                    retrying =
                        step MealEdit.RetryClicked failed
                in
                { failedPhase = toScreen failed |> .phase
                , error = toScreen failed |> .error
                , retryRequest = out MealEdit.RetryClicked failed
                , retryPhase = toScreen retrying |> .phase
                , unauthorized =
                    out
                        (MealEdit.MealLoaded "meal-1" (Err unauthorized))
                        (Tuple.first (MealEdit.init "meal-1"))
                }
                    |> Expect.equal
                        { failedPhase = "failed"
                        , error = Just networkErrorMessage
                        , retryRequest = MealEdit.RequestMeal "meal-1"
                        , retryPhase = "loading"
                        , unauthorized = MealEdit.SessionExpired
                        }
        , test "submitting sends the update payload and navigates to the detail on success" <|
            \_ ->
                let
                    editing : MealEdit.Model
                    editing =
                        loadedWithForm validForm

                    submitted : MealEdit.Model
                    submitted =
                        step MealEdit.SubmitClicked editing
                in
                { request = out MealEdit.SubmitClicked editing
                , submitError = toScreen submitted |> .submitError
                , success = out (MealEdit.SaveCompleted (Ok meal)) submitted
                }
                    |> Expect.equal
                        { request =
                            MealEdit.RequestUpdateMeal "meal-1"
                                { name = "Lunch"
                                , notes = Nothing
                                , totalQuantity = Nothing
                                , components =
                                    [ { item = { itemType = ItemRef.Product, id = "food-1" }
                                      , quantity = { amount = "2", unit = "serving" }
                                      }
                                    ]
                                }
                        , submitError = Nothing
                        , success = MealEdit.Navigate (MealShow "meal-1")
                        }
        , test "submitting without a name surfaces the validation error without a request" <|
            \_ ->
                { request =
                    out MealEdit.SubmitClicked (loadedWithForm Common.emptyFormFields)
                , error =
                    toScreen (step MealEdit.SubmitClicked (loadedWithForm Common.emptyFormFields))
                        |> .submitError
                }
                    |> Expect.equal
                        { request = MealEdit.NoOp
                        , error = Just "Name is required"
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , name : Maybe String
    , components : Maybe (List ( String, String, String ))
    , submitError : Maybe String
    , error : Maybe String
    }


toScreen : MealEdit.Model -> Screen
toScreen model =
    case model of
        MealEdit.LoadingEdit _ ->
            { phase = "loading"
            , name = Nothing
            , components = Nothing
            , submitError = Nothing
            , error = Nothing
            }

        MealEdit.EditLoadFailed failed ->
            { phase = "failed"
            , name = Nothing
            , components = Nothing
            , submitError = Nothing
            , error = Just failed.message
            }

        MealEdit.Editing loaded ->
            { phase = "editing"
            , name = Just loaded.fields.name
            , components =
                Just
                    (List.map
                        (\row -> ( row.productId, row.quantity, row.unit ))
                        loaded.fields.components
                    )
            , submitError = submitErrorMessage loaded.fields.submit
            , error = Nothing
            }



-- HELPERS


validForm : Common.FormFields
validForm =
    let
        row : Common.ComponentRow
        row =
            Common.emptyComponentRow 1

        fields : Common.FormFields
        fields =
            Common.emptyFormFields
    in
    { fields
        | name = "Lunch"
        , components =
            [ { row | productId = "food-1", quantity = "2", unit = "serving" } ]
    }


loadedWithForm : Common.FormFields -> MealEdit.Model
loadedWithForm fields =
    MealEdit.Editing
        { mealId = "meal-1"
        , meal = meal
        , fields = fields
        , nutrition = NutritionLoading View.Nutrients.defaultNutritionInput
        }


step : MealEdit.Msg -> MealEdit.Model -> MealEdit.Model
step msg model =
    first (MealEdit.update msg model)


out : MealEdit.Msg -> MealEdit.Model -> MealEdit.OutMsg
out msg model =
    third (MealEdit.update msg model)


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
          , quantity = { amount = "2", unit = "serving" }
          , nutritionSummary = Nothing
          }
        ]
    , createdAt = "now"
    , updatedAt = "now"
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
