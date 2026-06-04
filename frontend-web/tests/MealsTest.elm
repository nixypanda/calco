module MealsTest exposing (tests)

import Api.Client as Client
import Expect
import Page.Meals as Meals
import Route exposing (Route(..))
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meals"
        [ test "init requests meals" <|
            \_ ->
                Meals.init
                    |> Tuple.second
                    |> Expect.equal Meals.RequestMeals
        , test "load success stores meals" <|
            \_ ->
                Meals.update (Meals.MealsLoaded (Ok { items = [] })) (Tuple.first Meals.init)
                    |> first
                    |> .meals
                    |> Expect.equal (Just [])
        , test "load failure stores error" <|
            \_ ->
                Meals.update (Meals.MealsLoaded (Err Client.NetworkError)) (Tuple.first Meals.init)
                    |> first
                    |> .error
                    |> Expect.equal (Just "Network error")
        , test "empty list derives empty state" <|
            \_ ->
                Meals.emptyList { meals = Just [], error = Nothing }
                    |> Expect.equal True
        , test "meal summary includes notes when present" <|
            \_ ->
                Meals.mealSummaryText mealWithNotes
                    |> Expect.equal "0 components - Prep on Sunday"
        , test "meal summary omits separator when notes are absent" <|
            \_ ->
                Meals.mealSummaryText { mealWithNotes | notes = Nothing }
                    |> Expect.equal "0 components"
        , test "open meal navigates to meal detail" <|
            \_ ->
                Meals.update (Meals.OpenMealClicked "meal-1") (Tuple.first Meals.init)
                    |> third
                    |> Expect.equal (Meals.Navigate (MealDetail "meal-1"))
        , test "create meal navigates to meal form" <|
            \_ ->
                Meals.update Meals.CreateMealClicked (Tuple.first Meals.init)
                    |> third
                    |> Expect.equal (Meals.Navigate MealCreate)
        , test "back navigates home" <|
            \_ ->
                Meals.update Meals.BackClicked (Tuple.first Meals.init)
                    |> third
                    |> Expect.equal (Meals.Navigate (Diary Nothing))
        ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


mealWithNotes =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Just "Prep on Sunday"
    , totalQuantity = Nothing
    , components = []
    , createdAt = "now"
    , updatedAt = "now"
    }
