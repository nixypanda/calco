module Page.Meal.EditTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Edit as MealEdit
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Edit"
        [ test "a user edits a meal and saves it" <|
            \_ ->
                editedMeal
                    |> step MealEdit.SubmitClicked
                    |> step (MealEdit.SaveCompleted (Ok updatedMeal))
                    |> finish
                        (\( saved, completionOut ) ->
                            { screen = toScreen saved
                            , finalOut = completionOut
                            }
                                |> Expect.equal
                                    { screen =
                                        { name = "Lunch bowl"
                                        , components = [ ( "food-1", "3", "serving" ) ]
                                        , disabled = False
                                        , submitError = Nothing
                                        }
                                    , finalOut = MealEdit.Navigate (MealShow "meal-1")
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                editedMeal
                    |> step MealEdit.SubmitClicked
                    |> step (MealEdit.SaveCompleted (Err Client.NetworkError))
                    |> step MealEdit.SubmitClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { request = updateRequest outMsg
                            , disabled = (toScreen model).disabled
                            }
                                |> Expect.equal
                                    { request = Just lunchBowlRequest
                                    , disabled = True
                                    }
                        )
        , test "a failed load can be retried" <|
            \_ ->
                MealEdit.init "meal-1"
                    |> Story.start
                    |> step (MealEdit.MealLoaded "meal-1" (Err Client.NetworkError))
                    |> step MealEdit.RetryClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal (MealEdit.RequestMeal "meal-1")
                        )
        ]


type alias Screen =
    { name : String
    , components : List ( String, String, String )
    , disabled : Bool
    , submitError : Maybe String
    }


toScreen : MealEdit.Model -> Screen
toScreen model =
    case model of
        MealEdit.Editing loaded ->
            { name = loaded.fields.name
            , components =
                List.map
                    (\row -> ( row.productId, row.quantity, row.unit ))
                    loaded.fields.components
            , disabled = Common.isSubmitting loaded.fields.submit
            , submitError = submitError loaded.fields.submit
            }

        _ ->
            { name = "", components = [], disabled = False, submitError = Nothing }


submitError : Common.SubmitState -> Maybe String
submitError state =
    case state of
        Common.SubmitFailed message ->
            Just message

        _ ->
            Nothing


updateRequest : MealEdit.OutMsg -> Maybe Api.Meals.CreateMealRequest
updateRequest outMsg =
    case outMsg of
        MealEdit.RequestUpdateMeal "meal-1" request ->
            Just request

        _ ->
            Nothing


stepWithOut :
    MealEdit.Msg
    -> MealEdit.Model
    -> ( MealEdit.Model, MealEdit.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealEdit.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey MealEdit.Model MealEdit.OutMsg


step : MealEdit.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( MealEdit.Model, MealEdit.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


editedMeal : Journey
editedMeal =
    MealEdit.init "meal-1"
        |> Story.start
        |> step (MealEdit.MealLoaded "meal-1" (Ok meal))
        |> step (MealEdit.FormMsg (Common.NameChanged "Lunch bowl"))
        |> step (MealEdit.FormMsg (Common.ComponentQuantityChanged 1 "3"))


lunchBowlRequest : Api.Meals.CreateMealRequest
lunchBowlRequest =
    { name = "Lunch bowl"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "3", unit = "serving" }
          }
        ]
    }


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
    , createdAt = "2026-08-18T10:00:00Z"
    , updatedAt = "2026-08-18T10:00:00Z"
    }


updatedMeal : Meal
updatedMeal =
    { meal | name = "Lunch bowl" }
