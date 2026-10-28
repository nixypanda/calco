module Page.Meal.ListTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.List as MealList
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.List"
        [ test "a loaded list opens a meal, returns, and starts the create flow" <|
            \_ ->
                let
                    loaded : MealList.Model
                    loaded =
                        step
                            (MealList.MealsLoaded (Ok { items = [ lunchMeal, sideMeal ] }))
                            initModel

                    actions : Result String ( MealList.Model, List MealList.OutMsg )
                    actions =
                        runStepsResult stepWithOut
                            [ MealList.OpenMealClicked "meal-1"
                            , MealList.BackClicked
                            , MealList.CreateMealClicked
                            ]
                            loaded
                in
                case actions of
                    Ok ( final, [ openOut, backOut, createOut ] ) ->
                        { openOut = openOut
                        , backOut = backOut
                        , createOut = createOut
                        , screen = toScreen final
                        }
                            |> Expect.equal
                                { openOut = MealList.Navigate (MealShow "meal-1")
                                , backOut = MealList.Navigate (DiaryDay Nothing Nothing)
                                , createOut = MealList.Navigate MealCreate
                                , screen =
                                    { names = [ "Lunch", "Side salad" ], error = Nothing }
                                }

                    Ok _ ->
                        Expect.fail "the meal list story produced unexpected out messages"

                    Err message ->
                        Expect.fail message
        , test "a failed load returns to the diary, then re-entry loads and a 401 expires" <|
            \_ ->
                let
                    failed : MealList.Model
                    failed =
                        step (MealList.MealsLoaded (Err Client.NetworkError))
                            initModel

                    actions : Result String ( MealList.Model, List MealList.OutMsg )
                    actions =
                        runStepsResult stepWithOut
                            [ MealList.CreateMealClicked
                            , MealList.BackClicked
                            ]
                            failed

                    reentered : MealList.Model
                    reentered =
                        step (MealList.MealsLoaded (Ok { items = [ lunchMeal ] }))
                            initModel

                    expired : MealList.Model
                    expired =
                        step
                            (MealList.MealsLoaded (Err Fixtures.unauthorized))
                            reentered
                in
                case actions of
                    Ok ( _, [ createOut, backOut ] ) ->
                        { failed = toScreen failed
                        , createOut = createOut
                        , backOut = backOut
                        , reentryOut = Tuple.second MealList.init
                        , reentered = toScreen reentered
                        , screen = toScreen expired
                        , finalOut =
                            out
                                (MealList.MealsLoaded (Err Fixtures.unauthorized))
                                reentered
                        }
                            |> Expect.equal
                                { failed =
                                    { names = [], error = Just Fixtures.networkErrorMessage }
                                , createOut = MealList.Navigate MealCreate
                                , backOut = MealList.Navigate (DiaryDay Nothing Nothing)
                                , reentryOut = MealList.RequestMeals
                                , reentered = { names = [ "Lunch" ], error = Nothing }
                                , screen = { names = [], error = Just "Sign in again" }
                                , finalOut = MealList.SessionExpired
                                }

                    Ok _ ->
                        Expect.fail "the failed-load story produced unexpected out messages"

                    Err message ->
                        Expect.fail message
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


initModel : MealList.Model
initModel =
    Tuple.first MealList.init


step : MealList.Msg -> MealList.Model -> MealList.Model
step msg model =
    Fixtures.tupleFirst (MealList.update msg model)


out : MealList.Msg -> MealList.Model -> MealList.OutMsg
out msg model =
    Fixtures.tupleThird (MealList.update msg model)


stepWithOut : MealList.Msg -> MealList.Model -> Maybe ( MealList.Model, MealList.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealList.update msg model
    in
    if next == model && outMsg == MealList.NoOp then
        Nothing

    else
        Just ( next, outMsg )


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
