module Data.RouteTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Test exposing (Test, describe, test)
import Url


tests : Test
tests =
    describe "Data.Route.fromUrl"
        [ parses "/setup" BootstrapSetup
        , parses "/login" AuthLogin
        , parses "/admin" AdminDashboard
        , parses "/home" (DiaryDay Nothing)
        , parses "/home?date=2026-06-04" (DiaryDay (Just "2026-06-04"))
        , parses "/settings/goals" GoalSettings
        , parses "/logs/abc" (FoodLogEntry "abc")
        , parses "/search" (FoodSearch Nothing Nothing)
        , parses "/search?meal_slot=breakfast" (FoodSearch Nothing (Just Breakfast))
        , parses "/search?date=2026-06-04&meal_slot=breakfast"
            (FoodSearch (Just "2026-06-04") (Just Breakfast))
        , parses "/foods/abc" (FoodShow "abc" Nothing Nothing)
        , parses "/foods/abc?meal_slot=breakfast" (FoodShow "abc" Nothing (Just Breakfast))
        , parses "/foods/abc?date=2026-06-04&meal_slot=breakfast"
            (FoodShow "abc" (Just "2026-06-04") (Just Breakfast))
        , parses "/foods/custom/new" CustomFoodCreate
        , parses "/foods/custom/abc/edit" (CustomFoodEdit "abc")
        , parses "/foods/custom" CustomFoodList
        , parses "/meals" MealList
        , parses "/meals/new" MealCreate
        , parses "/meals/abc" (MealShow "abc")
        , parses "/meals/abc/edit" (MealEdit "abc")
        , parses "/unknown" NotFound
        ]


parses : String -> Route -> Test
parses path expected =
    test path <|
        \_ ->
            Url.fromString ("http://localhost" ++ path)
                |> Maybe.map Data.Route.fromUrl
                |> Expect.equal (Just expected)
