module Page.Meal.ListTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.List as MealList
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.List"
        [ test "a loaded list opens a meal" <|
            \_ ->
                loadedList
                    |> step (MealList.OpenMealClicked "meal-1")
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal (MealList.Navigate (MealShow "meal-1"))
                        )
        , test "a loaded list starts meal creation" <|
            \_ ->
                loadedList
                    |> step MealList.CreateMealClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal (MealList.Navigate MealCreate)
                        )
        , test "a failed load shows the error" <|
            \_ ->
                MealList.init
                    |> Story.start
                    |> step (MealList.MealsLoaded (Err Client.NetworkError))
                    |> finish
                        (\( model, _ ) ->
                            toScreen model
                                |> Expect.equal
                                    { names = []
                                    , error = Just Fixtures.networkErrorMessage
                                    }
                        )
        ]


type alias Screen =
    { names : List String
    , error : Maybe String
    }


toScreen : MealList.Model -> Screen
toScreen model =
    case model of
        MealList.Loaded meals ->
            { names = List.map .name meals, error = Nothing }

        MealList.LoadFailed message ->
            { names = [], error = Just message }

        MealList.Loading ->
            { names = [], error = Nothing }


stepWithOut :
    MealList.Msg
    -> MealList.Model
    -> ( MealList.Model, MealList.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealList.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey MealList.Model MealList.OutMsg


step : MealList.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( MealList.Model, MealList.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedList : Journey
loadedList =
    MealList.init
        |> Story.start
        |> step (MealList.MealsLoaded (Ok { items = [ lunchMeal, sideMeal ] }))


lunchMeal : Meal
lunchMeal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , nutritionSummary =
        Just
            { energyKcal = Just "420"
            , proteinG = Just "35"
            , carbsG = Just "45"
            , fatG = Just "12"
            , fiberG = Nothing
            }
    , components = []
    , createdAt = "2026-08-18T10:00:00Z"
    , updatedAt = "2026-08-18T10:00:00Z"
    }


sideMeal : Meal
sideMeal =
    { lunchMeal
        | id = "meal-2"
        , name = "Side salad"
        , nutritionSummary =
            Just
                { energyKcal = Just "180"
                , proteinG = Nothing
                , carbsG = Nothing
                , fatG = Nothing
                , fiberG = Nothing
                }
        , components = []
    }
