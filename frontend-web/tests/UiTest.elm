module UiTest exposing (tests)

{-| Tests for the design-system primitives in `Ui`.

The rendering components are pure `Element` construction with no DOM
available in elm-test, so only the places where the design system makes
a decision based on input are worth asserting on: the `chip`
background selection, the CSS variable block, and `isSmall`.

-}

import Element
import Expect
import String
import Test exposing (Test, describe, test)
import Ui
import Ui.Css as Css
import Ui.Theme as Theme exposing (Theme)


theme : Theme
theme =
    Theme.light


tests : Test
tests =
    describe "Ui"
        [ chipBehavior
        , cssVariables
        , deviceHelpers
        ]


chipBehavior : Test
chipBehavior =
    describe "chip"
        [ test "uses inputFill background when not selected" <|
            \_ ->
                Ui.chipBackground theme False
                    |> Expect.equal theme.chipBg
        , test "uses theme chip-selected background when selected" <|
            \_ ->
                Ui.chipBackground theme True
                    |> Expect.equal theme.chipSelectedBg
        ]


cssVariables : Test
cssVariables =
    describe "themeCssVariables"
        [ test "includes chip-selected and focus-ring theme values" <|
            \_ ->
                let
                    cssVars : String
                    cssVars =
                        Css.themeCssVariables theme
                in
                Expect.all
                    [ \_ ->
                        String.contains
                            ("--ui-chip-selected-bg: " ++ Css.toCssColor theme.chipSelectedBg)
                            cssVars
                            |> Expect.equal True
                    , \_ ->
                        String.contains
                            ("--ui-chip-selected-fg: " ++ Css.toCssColor theme.chipSelectedFg)
                            cssVars
                            |> Expect.equal True
                    , \_ ->
                        String.contains
                            ("--ui-focus-ring: " ++ Css.toCssColor theme.focusRing)
                            cssVars
                            |> Expect.equal True
                    ]
                    ()
        ]


deviceHelpers : Test
deviceHelpers =
    describe "device helpers"
        [ test "isSmall is True only for Phone" <|
            \_ ->
                [ Element.Device Element.Phone Element.Portrait
                , Element.Device Element.Tablet Element.Landscape
                , Element.Device Element.Desktop Element.Landscape
                , Element.Device Element.BigDesktop Element.Landscape
                ]
                    |> List.map Ui.isSmall
                    |> Expect.equal [ True, False, False, False ]
        ]
