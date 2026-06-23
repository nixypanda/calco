module Data.RouteTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)
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
        , fuzz routeFuzzer "route paths parse back to the same route" <|
            \route ->
                route
                    |> Data.Route.routeToPath
                    |> parsePath
                    |> Expect.equal (Just route)
        ]


parses : String -> Route -> Test
parses path expected =
    test path <|
        \_ ->
            Url.fromString ("http://localhost" ++ path)
                |> Maybe.map Data.Route.fromUrl
                |> Expect.equal (Just expected)


parsePath : String -> Maybe Route
parsePath path =
    Url.fromString ("http://localhost" ++ path)
        |> Maybe.map Data.Route.fromUrl


routeFuzzer : Fuzzer Route
routeFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Root
        , Fuzz.constant BootstrapSetup
        , Fuzz.constant AuthLogin
        , Fuzz.constant AdminDashboard
        , Fuzz.constant AdminCreateUser
        , Fuzz.map AdminEditUser safeSegmentFuzzer
        , Fuzz.map DiaryDay maybeDateFuzzer
        , Fuzz.constant GoalSettings
        , Fuzz.map FoodLogEntry safeSegmentFuzzer
        , Fuzz.map2 FoodSearch maybeDateFuzzer maybeMealSlotFuzzer
        , Fuzz.map3 FoodShow safeSegmentFuzzer maybeDateFuzzer maybeMealSlotFuzzer
        , Fuzz.constant CustomFoodList
        , Fuzz.constant CustomFoodCreate
        , Fuzz.map CustomFoodEdit safeSegmentFuzzer
        , Fuzz.map CustomFoodShow safeSegmentFuzzer
        , Fuzz.constant MealList
        , Fuzz.constant MealCreate
        , Fuzz.map MealShow safeSegmentFuzzer
        , Fuzz.map MealEdit safeSegmentFuzzer
        ]


maybeDateFuzzer : Fuzzer (Maybe String)
maybeDateFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Nothing
        , Fuzz.map Just dateStringFuzzer
        ]


maybeMealSlotFuzzer : Fuzzer (Maybe MealSlot)
maybeMealSlotFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Nothing
        , Fuzz.map Just mealSlotFuzzer
        ]


mealSlotFuzzer : Fuzzer MealSlot
mealSlotFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Breakfast
        , Fuzz.constant Lunch
        , Fuzz.constant Dinner
        , Fuzz.constant Snack
        , Fuzz.constant Other
        ]


dateStringFuzzer : Fuzzer String
dateStringFuzzer =
    Fuzz.map3 formatDate
        (Fuzz.intRange 1 9999)
        (Fuzz.intRange 1 12)
        (Fuzz.intRange 1 28)


formatDate : Int -> Int -> Int -> String
formatDate year month day =
    String.fromInt year ++ "-" ++ pad2 month ++ "-" ++ pad2 day


safeSegmentFuzzer : Fuzzer String
safeSegmentFuzzer =
    Fuzz.intRange 1 999999
        |> Fuzz.map (\value -> "id-" ++ String.fromInt value)


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value
