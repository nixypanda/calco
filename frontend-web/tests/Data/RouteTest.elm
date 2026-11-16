module Data.RouteTest exposing (tests)

import Data.MealSlot as MealSlot
import Data.Route as Route exposing (Route(..))
import Expect
import Lib.Date exposing (LocalDate)
import Support.Fixtures as Fixtures
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz, test)
import Url


{-| `Support.Fuzz.segment` never produces `""`, `"."`, or `".."`: backend
IDs are UUIDs, and browsers normalize dot segments even when percent-encoded, so
no `routeToPath` output could roundtrip those values. Percent signs, spaces,
slashes, unicode, and the reserved words "new"/"custom" are all generated.
-}
tests : Test
tests =
    describe "Data.Route"
        [ fuzz Support.route "routeToPath then fromUrl is the identity" <|
            \route ->
                route |> Route.routeToPath |> parsePath |> Expect.equal (Just route)
        , fuzz Support.route "primaryRoute is idempotent" <|
            \route ->
                Route.primaryRoute (Route.primaryRoute route)
                    |> Expect.equal (Route.primaryRoute route)
        , test "every nested route selects its shell destination" <|
            \_ ->
                destinationGroups
                    |> List.concatMap
                        (\( destination, routes ) ->
                            List.map
                                (\route ->
                                    Route.primaryRoute route |> Expect.equal destination
                                )
                                routes
                        )
                    |> expectAll
        , test "landing and non-app routes are their own destination" <|
            \_ ->
                [ Root
                , BootstrapSetup
                , AuthLogin
                , AdminDashboard
                , Library
                , Settings
                , FoodSearch Nothing Nothing
                , DiaryDay Nothing Nothing
                , NotFound
                ]
                    |> List.map (\route -> Route.primaryRoute route |> Expect.equal route)
                    |> expectAll
        , {- Plain goals settings stays context-free; the fuzzer covers the
             optional date/month roundtrip, while this pins the old URL.
          -}
          test "plain goals settings stays context-free" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        parsePath "/settings/goals"
                            |> Expect.equal (Just (GoalSettings Nothing Nothing))
                    , \_ ->
                        Route.routeToPath (GoalSettings Nothing Nothing)
                            |> Expect.equal "/settings/goals"
                    ]
                    ()
        , {- Negative exception: NotFound is the only route excluded from the
             roundtrip because `routeToPath NotFound == "/"` parses as `Root`.
             This case protects the intentional fallback for unknown URLs.
          -}
          test "an unrecognized URL parses to NotFound" <|
            \_ ->
                Url.fromString "http://localhost/definitely-not-a-route"
                    |> Maybe.map Route.fromUrl
                    |> Expect.equal (Just NotFound)
        ]


{-| Contextual and nested routes grouped by the bottom-nav or drawer item they
select. Every constructor that collapses to a destination is represented once,
so a new child route cannot silently fall outside navigation.
-}
destinationGroups : List ( Route, List Route )
destinationGroups =
    [ ( DiaryDay Nothing Nothing
      , [ DiaryDay (Just date) (Just "2026-07")
        , DiaryCalendar (Just "2026-07")
        , NutritionDetails (Just date)
        , GoalSettings (Just date) (Just "2026-07")
        , DiarySettings
        , FoodLogEntry "log-1" (Just date) Nothing
        ]
      )
    , ( FoodSearch Nothing Nothing
      , [ FoodSearch (Just date) (Just MealSlot.Lunch)
        , FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing
        , AdHocLogCreate (Just date) (Just MealSlot.Lunch)
        , AiLogCreate (Just date) (Just MealSlot.Lunch)
        ]
      )
    , ( Library
      , [ CustomFoodList
        , CustomFoodCreate
        , CustomFoodCreateWithAi
        , CustomFoodEdit "food-1"
        , CustomFoodShow "food-1"
        , MealList
        , MealCreate
        , MealShow "meal-1"
        , MealEdit "meal-1"
        ]
      )
    , ( Settings, [ SettingsApiKeys, SettingsApiKeyCreate ] )
    , ( AdminDashboard, [ AdminCreateUser, AdminEditUser "user-1" ] )
    ]


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()


parsePath : String -> Maybe Route
parsePath path =
    Url.fromString ("http://localhost" ++ path) |> Maybe.map Route.fromUrl


date : LocalDate
date =
    Fixtures.date "2026-07-20"
