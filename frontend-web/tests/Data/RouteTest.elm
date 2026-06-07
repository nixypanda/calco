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
        , parses "/logs/abc" (FoodLogEntry "abc")
        , parses "/search" (FoodSearch Nothing)
        , parses "/search?meal_slot=breakfast" (FoodSearch (Just Breakfast))
        , parses "/foods/abc" (FoodShow "abc" Nothing)
        , parses "/foods/abc?meal_slot=breakfast" (FoodShow "abc" (Just Breakfast))
        , parses "/foods/custom/new" CustomFoodCreate
        , parses "/foods/custom/abc/edit" (CustomFoodEdit "abc")
        , parses "/foods/custom" CustomFoodList
        , parses "/meals" MealList
        , parses "/meals/new" MealCreate
        , parses "/meals/abc" (MealShow "abc")
        , parses "/meals/abc/edit" (MealEdit "abc")
        , parses "/unknown" NotFound
        ]


parses : String -> Data.Route.Route -> Test
parses path expected =
    test path <|
        \_ ->
            Url.fromString ("http://localhost" ++ path)
                |> Maybe.map Data.Route.fromUrl
                |> Expect.equal (Just expected)
