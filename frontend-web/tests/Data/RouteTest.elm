module Data.RouteTest exposing (tests)

import Data.MealSlot as MealSlot
import Data.Route as Route exposing (Route(..))
import Expect
import Support.Fixtures as Fixtures
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz, test)
import Url


{-| `Support.Fuzz.segment` deliberately omits `""`, `"."`, and `".."`: backend
IDs are UUIDs, and browsers normalize dot segments even when percent-encoded, so
no `routeToPath` output could roundtrip those values. Percent signs, spaces,
slashes, unicode, and the reserved words "new"/"custom" are all generated.
-}
tests : Test
tests =
    describe "Data.Route"
        [ fuzz Support.route "routeToPath then fromUrl is the identity" <|
            \route ->
                route
                    |> Route.routeToPath
                    |> parsePath
                    |> Expect.equal (Just route)
        , test "reserved-word detail IDs roundtrip through their escaped segments" <|
            \_ ->
                reservedWordRoutes
                    |> List.map
                        (\route ->
                            route
                                |> Route.routeToPath
                                |> parsePath
                                |> Expect.equal (Just route)
                        )
                    |> expectAll
        , test "primaryRoute maps every detail family to its base family" <|
            \_ ->
                primaryRouteCases
                    |> List.map
                        (\( route, expected ) ->
                            Route.primaryRoute route
                                |> Expect.equal expected
                        )
                    |> expectAll
        , fuzz Support.route "primaryRoute never returns NotFound for a known route" <|
            \route ->
                Route.primaryRoute route
                    |> Expect.notEqual NotFound
        , fuzz Support.route "primaryRoute is idempotent" <|
            \route ->
                Route.primaryRoute (Route.primaryRoute route)
                    |> Expect.equal (Route.primaryRoute route)
        ]


reservedWordRoutes : List Route
reservedWordRoutes =
    [ MealShow "new"
    , MealEdit "new"
    , CustomFoodShow "new"
    , CustomFoodEdit "new"
    , FoodShow "custom" Nothing Nothing Nothing
    , AdminEditUser "new"
    ]


primaryRouteCases : List ( Route, Route )
primaryRouteCases =
    [ ( FoodShow "food-1" (Just Fixtures.today) (Just MealSlot.Breakfast) (Just "note")
      , FoodSearch (Just Fixtures.today) (Just MealSlot.Breakfast)
      )
    , ( CustomFoodCreate, CustomFoodList )
    , ( CustomFoodCreateWithAi, CustomFoodList )
    , ( CustomFoodEdit "food-1", CustomFoodList )
    , ( CustomFoodShow "food-1", CustomFoodList )
    , ( AdminCreateUser, AdminDashboard )
    , ( AdminEditUser "user-1", AdminDashboard )
    , ( MealCreate, MealList )
    , ( MealShow "meal-1", MealList )
    , ( MealEdit "meal-1", MealList )
    , ( SettingsApiKeyCreate, SettingsApiKeys )
    , ( FoodLogEntry "log-1" (Just Fixtures.today) (Just "2026-08")
      , DiaryDay Nothing Nothing
      )
    , ( AdHocLogCreate (Just Fixtures.today) (Just MealSlot.Lunch)
      , FoodSearch (Just Fixtures.today) (Just MealSlot.Lunch)
      )
    , ( AiLogCreate (Just Fixtures.today) (Just MealSlot.Dinner)
      , FoodSearch (Just Fixtures.today) (Just MealSlot.Dinner)
      )
    , ( DiaryDay (Just Fixtures.today) (Just "2026-08"), DiaryDay Nothing Nothing )
    , ( DiaryCalendar (Just "2026-08"), DiaryDay Nothing Nothing )
    , ( NutritionDetails (Just Fixtures.today), DiaryDay Nothing Nothing )
    , ( FoodSearch (Just Fixtures.today) (Just MealSlot.Snack)
      , FoodSearch (Just Fixtures.today) (Just MealSlot.Snack)
      )
    ]


parsePath : String -> Maybe Route
parsePath path =
    Url.fromString ("http://localhost" ++ path)
        |> Maybe.map Route.fromUrl


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()
