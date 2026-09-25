module Page.Meal.ListTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.List as MealList
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


tests : Test
tests =
    describe "Page.Meal.List"
        [ test "loading the meal list requests meals and renders each meal summary" <|
            \_ ->
                let
                    loaded : MealList.Model
                    loaded =
                        step
                            (MealList.MealsLoaded (Ok { items = [ mealWithNotes ] }))
                            (Tuple.first MealList.init)
                in
                { initial = Tuple.second MealList.init
                , phase = toScreen loaded |> .phase
                , summaries = toScreen loaded |> .summaries
                }
                    |> Expect.equal
                        { initial = MealList.RequestMeals
                        , phase = "loaded"
                        , summaries = [ "420 kcal ⋅ 0 components" ]
                        }
        , test "a failed meal list load shows the error and a 401 expires the session" <|
            \_ ->
                let
                    loading : MealList.Model
                    loading =
                        Tuple.first MealList.init

                    failed : MealList.Model
                    failed =
                        step (MealList.MealsLoaded (Err Client.NetworkError)) loading
                in
                { phase = toScreen failed |> .phase
                , error = toScreen failed |> .error
                , unauthorized = out (MealList.MealsLoaded (Err unauthorized)) loading
                }
                    |> Expect.equal
                        { phase = "failed"
                        , error = Just networkErrorMessage
                        , unauthorized = MealList.SessionExpired
                        }
        , test "list actions navigate to detail, create, and back to the diary" <|
            \_ ->
                let
                    loading : MealList.Model
                    loading =
                        Tuple.first MealList.init
                in
                { open = out (MealList.OpenMealClicked "meal-1") loading
                , create = out MealList.CreateMealClicked loading
                , back = out MealList.BackClicked loading
                }
                    |> Expect.equal
                        { open = MealList.Navigate (MealShow "meal-1")
                        , create = MealList.Navigate MealCreate
                        , back = MealList.Navigate (DiaryDay Nothing Nothing)
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , summaries : List String
    , error : Maybe String
    }


toScreen : MealList.Model -> Screen
toScreen model =
    case model of
        MealList.Loaded meals ->
            { phase = "loaded"
            , summaries = List.map MealList.mealSummaryText meals
            , error = Nothing
            }

        MealList.LoadFailed message ->
            { phase = "failed"
            , summaries = []
            , error = Just message
            }

        MealList.Loading ->
            { phase = "loading"
            , summaries = []
            , error = Nothing
            }



-- HELPERS


step : MealList.Msg -> MealList.Model -> MealList.Model
step msg model =
    first (MealList.update msg model)


out : MealList.Msg -> MealList.Model -> MealList.OutMsg
out msg model =
    third (MealList.update msg model)


mealWithNotes : Meal
mealWithNotes =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Just "Prep on Sunday"
    , totalQuantity = Nothing
    , nutritionSummary =
        Just
            { energyKcal = Just "420"
            , proteinG = Nothing
            , carbsG = Nothing
            , fatG = Nothing
            , fiberG = Nothing
            }
    , components = []
    , createdAt = "now"
    , updatedAt = "now"
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
