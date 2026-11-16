module MainTest exposing (tests)

{-| Laws for the device-class decision and the chrome navigation rewrite.

Width classification is one full-range property: every width has exactly one
class according to the documented breakpoints. The 1439/1440 workspace boundary
is asserted deterministically inside that property, not as a separate example.

-}

import Chrome
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Main
import Page
import Support.Fixtures as Fixtures
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3, test)
import Translations.Util exposing (Language(..))
import Ui.Env as UiEnv exposing (Env, Viewport(..))
import Ui.Theme as Theme


tests : Test
tests =
    describe "Main"
        [ describe "classifyDevice"
            [ fullWidthRange
            , classDependsOnlyOnWidth
            , orientationLaw
            ]
        , describe "reclassifyDevice" [ reclassifyLaw ]
        , describe "viewport classification"
            [ viewportBreakpoint
            , viewportResizeIsSemantic
            ]
        , describe "normalizeChromeNavigation"
            [ genericSearchNavigation
            , navigationIsUnchangedOtherwise
            ]
        , describe "drawer focus" [ drawerFocusFollowsVisibility ]
        , describe "rendersOnePane" [ renderedPaneLayoutDrivesScrollReset ]
        , describe "logoutStillApplies" [ staleLogoutIsIgnored ]
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


viewportBreakpoint : Test
viewportBreakpoint =
    test "the viewport category changes between 359 and 360px" <|
        \_ ->
            Expect.all
                [ \_ -> UiEnv.viewportForWidth 320 |> Expect.equal NarrowViewport
                , \_ -> UiEnv.viewportForWidth 359 |> Expect.equal NarrowViewport
                , \_ -> UiEnv.viewportForWidth 360 |> Expect.equal RegularViewport
                , \_ -> UiEnv.viewportForWidth 485 |> Expect.equal RegularViewport
                ]
                ()


{-| The semantic comparison is what keeps a continuous drag from re-rendering
inside one category, while still crossing the breakpoint in either direction.
-}
viewportResizeIsSemantic : Test
viewportResizeIsSemantic =
    test "resize changes the model only across the viewport category" <|
        \_ ->
            Expect.all
                [ \_ -> Main.reclassifyViewport 320 NarrowViewport |> Expect.equal Nothing
                , \_ -> Main.reclassifyViewport 359 NarrowViewport |> Expect.equal Nothing
                , \_ ->
                    Main.reclassifyViewport 360 NarrowViewport
                        |> Expect.equal (Just RegularViewport)
                , \_ -> Main.reclassifyViewport 485 RegularViewport |> Expect.equal Nothing
                , \_ ->
                    Main.reclassifyViewport 359 RegularViewport
                        |> Expect.equal (Just NarrowViewport)
                ]
                ()


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


{-| A closing drawer can happen through Escape, the scrim, browser Back, or a
layout change; all of them return focus to the trigger. Opening it moves focus
to the drawer's close control. No other transition steals focus.
-}
drawerFocusFollowsVisibility : Test
drawerFocusFollowsVisibility =
    test "focus follows the drawer lifecycle" <|
        \_ ->
            let
                opened : Chrome.Model
                opened =
                    Chrome.update Chrome.MenuClicked Chrome.init
                        |> Tuple.first

                closed : Chrome.Model
                closed =
                    Chrome.close opened
            in
            Expect.all
                [ \_ ->
                    Main.drawerFocusTarget Chrome.init opened
                        |> Expect.equal (Just "app-drawer-close")
                , \_ ->
                    Main.drawerFocusTarget opened closed
                        |> Expect.equal (Just "app-menu-trigger")
                , \_ -> Main.drawerFocusTarget opened opened |> Expect.equal Nothing
                , \_ -> Main.drawerFocusTarget Chrome.init Chrome.init |> Expect.equal Nothing
                ]
                ()


{-| The scroll-reset decision follows `Ui.Workspace`'s visibility rule, so the
same two-pane model resets on Phone/Tablet (one rendered pane) but not on a
desktop (two rendered panes).
-}
renderedPaneLayoutDrivesScrollReset : Test
renderedPaneLayoutDrivesScrollReset =
    test "scroll resets from the rendered pane layout, not the model pane count" <|
        \_ ->
            let
                twoPaneRoute : Route
                twoPaneRoute =
                    DiaryDay (Just Fixtures.today) (Just "2026-07")

                twoPanePage : Page.Model
                twoPanePage =
                    pageFor twoPaneRoute

                onePanePage : Page.Model
                onePanePage =
                    pageFor MealList

                bootPage : Page.Model
                bootPage =
                    Page.init { route = twoPaneRoute, today = Nothing }
                        |> Fixtures.tupleFirst
            in
            Expect.all
                [ \_ -> scrollOn Phone twoPaneRoute twoPanePage |> Expect.equal True
                , \_ -> scrollOn Tablet twoPaneRoute twoPanePage |> Expect.equal True
                , \_ -> scrollOn Desktop twoPaneRoute twoPanePage |> Expect.equal False
                , \_ -> scrollOn BigDesktop twoPaneRoute twoPanePage |> Expect.equal False
                , \_ -> scrollOn Desktop MealList onePanePage |> Expect.equal True
                , \_ -> Page.isLoading bootPage |> Expect.equal True
                , \_ -> scrollOn Phone twoPaneRoute bootPage |> Expect.equal True
                , \_ -> scrollOn Desktop twoPaneRoute bootPage |> Expect.equal False
                ]
                ()


{-| A late completion from an earlier logout, or any completion after the flag
was cleared by a new login, must not clear the current session.
-}
staleLogoutIsIgnored : Test
staleLogoutIsIgnored =
    test "only the active logout generation can tear down the session" <|
        \_ ->
            Expect.all
                [ \_ -> Main.logoutStillApplies True 2 2 |> Expect.equal True
                , \_ -> Main.logoutStillApplies True 1 2 |> Expect.equal False
                , \_ -> Main.logoutStillApplies False 2 2 |> Expect.equal False
                ]
                ()


pageFor : Route -> Page.Model
pageFor route =
    Page.init { route = route, today = Just Fixtures.today }
        |> Fixtures.tupleFirst


scrollEnv : DeviceClass -> Env
scrollEnv class =
    { theme = Theme.forMode Theme.Light
    , device = { class = class, orientation = Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }


scrollOn : DeviceClass -> Route -> Page.Model -> Bool
scrollOn class route page =
    Main.rendersOnePane (scrollEnv class) route page


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
