module MainTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Main
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Main.normalizeChromeNavigation"
        [ test "adds current diary date to generic food search navigation" <|
            \_ ->
                Main.normalizeChromeNavigation
                    (DiaryDay (Just "2026-05-29") Nothing)
                    (FoodSearch Nothing Nothing)
                    |> Expect.equal (FoodSearch (Just "2026-05-29") Nothing)
        , test "leaves generic food search unchanged without a diary date" <|
            \_ ->
                Main.normalizeChromeNavigation
                    (DiaryDay Nothing Nothing)
                    (FoodSearch Nothing Nothing)
                    |> Expect.equal (FoodSearch Nothing Nothing)
        , test "leaves explicit food search context unchanged" <|
            \_ ->
                Main.normalizeChromeNavigation
                    (DiaryDay (Just "2026-05-29") Nothing)
                    (FoodSearch (Just "2026-06-01") (Just Lunch))
                    |> Expect.equal (FoodSearch (Just "2026-06-01") (Just Lunch))
        , test "leaves unrelated navigation unchanged" <|
            \_ ->
                Main.normalizeChromeNavigation
                    (DiaryDay (Just "2026-05-29") Nothing)
                    CustomFoodList
                    |> Expect.equal CustomFoodList
        ]
