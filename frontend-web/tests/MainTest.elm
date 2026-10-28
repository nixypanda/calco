module MainTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Main
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3, test)


tests : Test
tests =
    describe "Main"
        [ describe "classifyDevice"
            [ phoneWidths
            , tabletWidths
            , desktopWidths
            , bigDesktopWidths
            , workspaceBoundary
            , widthBoundaries
            , classDependsOnlyOnWidth
            , orientationLaw
            ]
        , describe "reclassifyDevice"
            [ reclassifyIsNoOp
            , reclassifyMatchesClassification
            ]
        , describe "normalizeChromeNavigation"
            [ genericSearchInheritsDiaryDate
            , navigationIsUnchangedOutsideDatedDiary
            , navigationIsUnchangedForNonGenericTarget
            , explicitSearchContextIsUnchanged
            ]
        ]


phoneWidths : Test
phoneWidths =
    fuzz (Fuzz.intRange 0 599) "widths below 600 are phones" <|
        \widthValue ->
            Main.classifyDevice widthValue 900
                |> .class
                |> Expect.equal Phone


tabletWidths : Test
tabletWidths =
    fuzz (Fuzz.intRange 600 1439) "widths from 600 through 1439 are tablets" <|
        \widthValue ->
            Main.classifyDevice widthValue 900
                |> .class
                |> Expect.equal Tablet


desktopWidths : Test
desktopWidths =
    fuzz (Fuzz.intRange 1440 1920) "widths from 1440 through 1920 are desktops" <|
        \widthValue ->
            Main.classifyDevice widthValue 900
                |> .class
                |> Expect.equal Desktop


bigDesktopWidths : Test
bigDesktopWidths =
    fuzz (Fuzz.intRange 1921 100000) "widths above 1920 are big desktops" <|
        \widthValue ->
            Main.classifyDevice widthValue 900
                |> .class
                |> Expect.equal BigDesktop


workspaceBoundary : Test
workspaceBoundary =
    test "the workspace boundary stays at 1439 tablet and 1440 desktop" <|
        \_ ->
            ( Main.classifyDevice 1439 900 |> .class
            , Main.classifyDevice 1440 900 |> .class
            )
                |> Expect.equal ( Tablet, Desktop )


widthBoundaries : Test
widthBoundaries =
    test "device class switches at 599/600, 1439/1440, and 1920/1921" <|
        \_ ->
            [ ( 599, Phone )
            , ( 600, Tablet )
            , ( 1439, Tablet )
            , ( 1440, Desktop )
            , ( 1920, Desktop )
            , ( 1921, BigDesktop )
            ]
                |> List.map
                    (\( widthValue, expected ) ->
                        Main.classifyDevice widthValue 900
                            |> .class
                            |> Expect.equal expected
                            |> Expect.onFail ("width " ++ String.fromInt widthValue)
                    )
                |> expectAll


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


reclassifyIsNoOp : Test
reclassifyIsNoOp =
    fuzz2 widthFuzzer heightFuzzer "reclassifying the current classification changes nothing" <|
        \widthValue heightValue ->
            Main.reclassifyDevice widthValue
                heightValue
                (Main.classifyDevice widthValue heightValue)
                |> Expect.equal Nothing


{-| The full two-branch law: a changed classification is always returned, not
silently dropped as if every resize were a no-op.
-}
reclassifyMatchesClassification : Test
reclassifyMatchesClassification =
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
            Main.reclassifyDevice widthValue heightValue current
                |> Expect.equal
                    (if next == current then
                        Nothing

                     else
                        Just next
                    )
        )


genericSearchInheritsDiaryDate : Test
genericSearchInheritsDiaryDate =
    fuzz2 FuzzSupport.localDate
        (Fuzz.maybe FuzzSupport.monthPeriod)
        "a generic food search under a dated diary page inherits its date"
        (\date calendarMonth ->
            Main.normalizeChromeNavigation
                (DiaryDay (Just date) calendarMonth)
                (FoodSearch Nothing Nothing)
                |> Expect.equal (FoodSearch (Just date) Nothing)
        )


navigationIsUnchangedOutsideDatedDiary : Test
navigationIsUnchangedOutsideDatedDiary =
    fuzz2 nonDatedDiaryCurrent
        routeFuzzer
        "navigation is unchanged for every current route except a dated diary page"
        (\current target ->
            Main.normalizeChromeNavigation current target
                |> Expect.equal target
        )


{-| For a dated diary page, every target other than the generic
`FoodSearch Nothing Nothing` is left untouched.
-}
navigationIsUnchangedForNonGenericTarget : Test
navigationIsUnchangedForNonGenericTarget =
    fuzz3 FuzzSupport.localDate
        (Fuzz.maybe FuzzSupport.monthPeriod)
        navigableTarget
        "a dated diary page leaves every non-generic target unchanged"
        (\date calendarMonth target ->
            Main.normalizeChromeNavigation
                (DiaryDay (Just date) calendarMonth)
                target
                |> Expect.equal target
        )


explicitSearchContextIsUnchanged : Test
explicitSearchContextIsUnchanged =
    fuzz2 FuzzSupport.localDate
        explicitFoodSearch
        "an explicit food search context is never rewritten"
        (\diaryDate target ->
            Main.normalizeChromeNavigation
                (DiaryDay (Just diaryDate) Nothing)
                target
                |> Expect.equal target
        )


{-| Every current route except `DiaryDay (Just date) _`, including
`DiaryDay Nothing _` and `NotFound`.
-}
nonDatedDiaryCurrent : Fuzzer Route
nonDatedDiaryCurrent =
    routeFuzzer
        |> Fuzz.map
            (\current ->
                case current of
                    DiaryDay _ calendarMonth ->
                        DiaryDay Nothing calendarMonth

                    _ ->
                        current
            )


{-| A food search context that is not the generic `FoodSearch Nothing Nothing`
target: at least one of its date and slot is explicit.
-}
explicitFoodSearch : Fuzzer Route
explicitFoodSearch =
    Fuzz.oneOf
        [ Fuzz.map (\date -> FoodSearch (Just date) Nothing) FuzzSupport.localDate
        , Fuzz.map (\slot -> FoodSearch Nothing (Just slot)) FuzzSupport.mealSlot
        , Fuzz.map2
            (\date slot -> FoodSearch (Just date) (Just slot))
            FuzzSupport.localDate
            FuzzSupport.mealSlot
        ]


{-| Any target except the generic `FoodSearch Nothing Nothing`, which is the one
route a chrome navigation rewrites. Mapping the excluded case avoids
`Fuzz.filter` retries and keeps the law total.
-}
navigableTarget : Fuzzer Route
navigableTarget =
    routeFuzzer
        |> Fuzz.map
            (\target ->
                case target of
                    FoodSearch Nothing Nothing ->
                        FoodSearch Nothing (Just Lunch)

                    _ ->
                        target
            )


routeFuzzer : Fuzzer Route
routeFuzzer =
    Fuzz.oneOf [ FuzzSupport.route, Fuzz.constant NotFound ]


widthFuzzer : Fuzzer Int
widthFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.intRange 0 2560 )
        , ( 1, Fuzz.oneOfValues [ 0, 599, 600, 1439, 1440, 1920, 1921, 2560 ] )
        ]


heightFuzzer : Fuzzer Int
heightFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.intRange 0 2560 )
        , ( 1, Fuzz.oneOfValues [ 0, 1, 599, 600, 1439, 1440, 1920, 1921, 2560 ] )
        ]


expectAll : List Expectation -> Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()
