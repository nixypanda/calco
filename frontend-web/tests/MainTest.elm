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
        [ test "reports a resize that crosses into another device class" <|
            \_ ->
                Main.reclassifyDevice 1500
                    800
                    (Main.classifyDevice 420 900)
                    |> Expect.equal
                        (Just (Main.classifyDevice 1500 800))
        , test "reports a resize that only flips orientation" <|
            \_ ->
                Main.reclassifyDevice 550
                    400
                    (Main.classifyDevice 500 900)
                    |> Expect.equal
                        (Just (Main.classifyDevice 550 400))
        , test "does not change class when only height crosses an elm-ui breakpoint" <|
            \_ ->
                Main.reclassifyDevice 1000
                    700
                    (Main.classifyDevice 1000 500)
                    |> Expect.equal Nothing
        , test "uses the safe workspace width as the desktop breakpoint" <|
            \_ ->
                ( Main.classifyDevice 1439 900 |> .class
                , Main.classifyDevice 1440 900 |> .class
                )
                    |> Expect.equal ( Element.Tablet, Element.Desktop )
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
        ]
