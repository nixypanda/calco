module MainTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Element
import Expect
import Main
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Main"
        [ normalizeChromeNavigationTests
        , reclassifyDeviceTests
        ]


reclassifyDeviceTests : Test
reclassifyDeviceTests =
    describe "Main.reclassifyDevice"
        [ test "ignores a resize that keeps the same classification" <|
            \_ ->
                Main.reclassifyDevice 1300
                    800
                    (Element.classifyDevice { width = 1250, height = 800 })
                    |> Expect.equal Nothing
        , test "ignores a resize back to the exact same size" <|
            \_ ->
                Main.reclassifyDevice 420
                    900
                    (Element.classifyDevice { width = 420, height = 900 })
                    |> Expect.equal Nothing
        , test "reports a resize that crosses into another device class" <|
            \_ ->
                Main.reclassifyDevice 1300
                    800
                    (Element.classifyDevice { width = 420, height = 900 })
                    |> Expect.equal
                        (Just (Element.classifyDevice { width = 1300, height = 800 }))
        , test "reports a resize that only flips orientation" <|
            \_ ->
                Main.reclassifyDevice 550
                    400
                    (Element.classifyDevice { width = 500, height = 900 })
                    |> Expect.equal
                        (Just (Element.classifyDevice { width = 550, height = 400 }))
        ]


normalizeChromeNavigationTests : Test
normalizeChromeNavigationTests =
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
