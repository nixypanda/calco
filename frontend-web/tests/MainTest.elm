module MainTest exposing (tests)

{-| Laws for the device-class decision and the chrome navigation rewrite.

Width classification is one full-range property: every width has exactly one
class according to the documented breakpoints. The 1439/1440 workspace boundary
is asserted deterministically inside that property, not as a separate example.

-}

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Main
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "Main"
        [ describe "classifyDevice"
            [ fullWidthRange
            , classDependsOnlyOnWidth
            , orientationLaw
            ]
        , describe "reclassifyDevice" [ reclassifyLaw ]
        , describe "normalizeChromeNavigation"
            [ genericSearchNavigation
            , navigationIsUnchangedOtherwise
            ]
        ]


fullWidthRange : Test
fullWidthRange =
    fuzz widthFuzzer "every width maps to exactly one device class" <|
        \widthValue ->
            Expect.all
                [ \_ ->
                    Main.classifyDevice widthValue 900
                        |> .class
                        |> Expect.equal (expectedClass widthValue)
                , \_ -> boundaryCases |> List.map boundaryExpectation |> expectAll
                ]
                ()


boundaryCases : List ( Int, DeviceClass )
boundaryCases =
    [ ( 599, Phone )
    , ( 600, Tablet )
    , ( 1439, Tablet )
    , ( 1440, Desktop )
    , ( 1920, Desktop )
    , ( 1921, BigDesktop )
    ]


boundaryExpectation : ( Int, DeviceClass ) -> Expectation
boundaryExpectation ( widthValue, expected ) =
    Main.classifyDevice widthValue 900
        |> .class
        |> Expect.equal expected
        |> Expect.onFail ("width " ++ String.fromInt widthValue)


expectedClass : Int -> DeviceClass
expectedClass widthValue =
    if widthValue < 600 then
        Phone

    else if widthValue < 1440 then
        Tablet

    else if widthValue <= 1920 then
        Desktop

    else
        BigDesktop


classDependsOnlyOnWidth : Test
classDependsOnlyOnWidth =
    fuzz3 widthFuzzer
        heightFuzzer
        heightFuzzer
        "the device class depends only on width, not height"
        (\widthValue firstHeight secondHeight ->
            (Main.classifyDevice widthValue firstHeight |> .class)
                |> Expect.equal (Main.classifyDevice widthValue secondHeight |> .class)
        )


orientationLaw : Test
orientationLaw =
    fuzz2 widthFuzzer
        heightFuzzer
        "orientation is portrait exactly when width is less than height"
        (\widthValue heightValue ->
            ((Main.classifyDevice widthValue heightValue |> .orientation) == Portrait)
                |> Expect.equal (widthValue < heightValue)
        )


{-| The full two-branch law: a changed classification is returned as `Just` the
new device, and reclassifying the current classification is a no-op.
-}
reclassifyLaw : Test
reclassifyLaw =
    fuzz3 widthFuzzer
        heightFuzzer
        FuzzSupport.device
        "reclassify returns Just the new device exactly when it differs"
        (\widthValue heightValue current ->
            let
                next : Element.Device
                next =
                    Main.classifyDevice widthValue heightValue
            in
            Expect.all
                [ \_ ->
                    Main.reclassifyDevice widthValue heightValue current
                        |> Expect.equal
                            (if next == current then
                                Nothing

                             else
                                Just next
                            )
                , \_ ->
                    Main.reclassifyDevice widthValue heightValue next |> Expect.equal Nothing
                ]
                ()
        )


genericSearchNavigation : Test
genericSearchNavigation =
    fuzz routeFuzzer
        "a generic food search inherits a date only from a dated diary page"
        (\current ->
            let
                expected : Route
                expected =
                    case current of
                        DiaryDay (Just date) _ ->
                            FoodSearch (Just date) Nothing

                        _ ->
                            FoodSearch Nothing Nothing
            in
            Main.normalizeChromeNavigation current (FoodSearch Nothing Nothing)
                |> Expect.equal expected
        )


{-| The converse half of the rewrite law: every target other than the generic
`FoodSearch Nothing Nothing` is left untouched, whatever the current route.
-}
navigationIsUnchangedOtherwise : Test
navigationIsUnchangedOtherwise =
    fuzz2 routeFuzzer
        navigableTarget
        "navigation is unchanged unless a dated diary page targets a generic search"
        (\current target ->
            Main.normalizeChromeNavigation current target |> Expect.equal target
        )


{-| Any target except the generic `FoodSearch Nothing Nothing`, which is the one
route a chrome navigation rewrites. Mapping the excluded case avoids
`Fuzz.filter` retries and keeps the law total.
-}
navigableTarget : Fuzzer Route
navigableTarget =
    Fuzz.oneOf
        [ routeFuzzer
            |> Fuzz.map
                (\target ->
                    case target of
                        FoodSearch Nothing Nothing ->
                            FoodSearch Nothing (Just Lunch)

                        _ ->
                            target
                )
        , Fuzz.map (\slot -> FoodSearch Nothing (Just slot)) FuzzSupport.mealSlot
        ]


routeFuzzer : Fuzzer Route
routeFuzzer =
    Fuzz.oneOf [ FuzzSupport.route, Fuzz.constant NotFound ]


widthFuzzer : Fuzzer Int
widthFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.intRange 0 100000 )
        , ( 1, Fuzz.oneOfValues [ 0, 599, 600, 1439, 1440, 1920, 1921, 100000 ] )
        ]


heightFuzzer : Fuzzer Int
heightFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.intRange 0 100000 )
        , ( 1, Fuzz.oneOfValues [ 0, 1, 599, 600, 1439, 1440, 1920, 1921, 100000 ] )
        ]


expectAll : List Expectation -> Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()
