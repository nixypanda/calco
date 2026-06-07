module Page.Meal.ListTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.List as MealList
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.List"
        [ test "init requests meals" <|
            \_ ->
                MealList.init
                    |> Tuple.second
                    |> Expect.equal MealList.RequestMeals
        , test "load success stores meals" <|
            \_ ->
                MealList.update
                    (MealList.MealsLoaded (Ok { items = [] }))
                    (Tuple.first MealList.init)
                    |> first
                    |> mealsOf
                    |> Expect.equal (Just [])
        , test "load failure stores error" <|
            \_ ->
                MealList.update
                    (MealList.MealsLoaded (Err Client.NetworkError))
                    (Tuple.first MealList.init)
                    |> first
                    |> errorOf
                    |> Expect.equal (Just "Network error")
        , test "empty list derives empty state" <|
            \_ ->
                MealList.update
                    (MealList.MealsLoaded (Ok { items = [] }))
                    (Tuple.first MealList.init)
                    |> first
                    |> mealsOf
                    |> Expect.equal (Just [])
        , test "meal summary includes notes when present" <|
            \_ ->
                MealList.mealSummaryText mealWithNotes
                    |> Expect.equal "420 kcal ⋅ 0 components"
        , test "meal summary omits separator when notes are absent" <|
            \_ ->
                MealList.mealSummaryText { mealWithNotes | notes = Nothing }
                    |> Expect.equal "420 kcal ⋅ 0 components"
        , test "open meal navigates to meal detail" <|
            \_ ->
                MealList.update (MealList.OpenMealClicked "meal-1") (Tuple.first MealList.init)
                    |> third
                    |> Expect.equal (MealList.Navigate (MealShow "meal-1"))
        , test "create meal navigates to meal form" <|
            \_ ->
                MealList.update MealList.CreateMealClicked (Tuple.first MealList.init)
                    |> third
                    |> Expect.equal (MealList.Navigate MealCreate)
        , test "back navigates home" <|
            \_ ->
                MealList.update MealList.BackClicked (Tuple.first MealList.init)
                    |> third
                    |> Expect.equal (MealList.Navigate (DiaryDay Nothing))
        ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


mealsOf : MealList.Model -> Maybe (List Meal)
mealsOf model =
    case model of
        MealList.Loaded loaded ->
            Just loaded.meals

        _ ->
            Nothing


errorOf : MealList.Model -> Maybe String
errorOf model =
    case model of
        MealList.LoadFailed message ->
            Just message

        MealList.Loaded { action } ->
            case action of
                MealList.DeleteFailed message ->
                    Just message

                _ ->
                    Nothing

        MealList.Loading ->
            Nothing


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
