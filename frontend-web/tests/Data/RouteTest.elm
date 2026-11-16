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
        , fuzz Support.route
            "primaryRoute is idempotent and never maps a known route to NotFound"
          <|
            \route ->
                Expect.all
                    [ \_ ->
                        Route.primaryRoute (Route.primaryRoute route)
                            |> Expect.equal (Route.primaryRoute route)
                    ]
                    ()
        , test "nav destinations group contextual and nested routes" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Route.primaryRoute (DiaryCalendar (Just "2026-07"))
                            |> Expect.equal (DiaryDay Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute (GoalSettings Nothing Nothing)
                            |> Expect.equal (DiaryDay Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute DiarySettings
                            |> Expect.equal (DiaryDay Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute (FoodLogEntry "log-1" (Just date) Nothing)
                            |> Expect.equal (DiaryDay Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute (FoodSearch (Just date) (Just MealSlot.Lunch))
                            |> Expect.equal (FoodSearch Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute
                            (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                            |> Expect.equal (FoodSearch Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute (AdHocLogCreate (Just date) (Just MealSlot.Lunch))
                            |> Expect.equal (FoodSearch Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute (AiLogCreate (Just date) (Just MealSlot.Lunch))
                            |> Expect.equal (FoodSearch Nothing Nothing)
                    , \_ ->
                        Route.primaryRoute CustomFoodList
                            |> Expect.equal Library
                    , \_ ->
                        Route.primaryRoute (CustomFoodShow "food-1")
                            |> Expect.equal Library
                    , \_ ->
                        Route.primaryRoute MealList
                            |> Expect.equal Library
                    , \_ ->
                        Route.primaryRoute (MealShow "meal-1")
                            |> Expect.equal Library
                    , \_ ->
                        Route.primaryRoute SettingsApiKeys
                            |> Expect.equal Settings
                    , \_ ->
                        Route.primaryRoute SettingsApiKeyCreate
                            |> Expect.equal Settings
                    ]
                    ()
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


parsePath : String -> Maybe Route
parsePath path =
    Url.fromString ("http://localhost" ++ path) |> Maybe.map Route.fromUrl


date : LocalDate
date =
    Fixtures.date "2026-07-20"
