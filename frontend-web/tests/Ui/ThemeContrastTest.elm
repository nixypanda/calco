module Ui.ThemeContrastTest exposing (tests)

import Element exposing (Color)
import Expect
import Test exposing (Test, describe, test)
import Ui.Theme as Theme exposing (Theme)


{-| WCAG AA for normal text.
-}
minTextContrast : Float
minTextContrast =
    4.5


{-| WCAG AA for large text and non-text UI (such as the focus ring).
-}
minUiContrast : Float
minUiContrast =
    3.0


tests : Test
tests =
    describe "Ui.Theme contrast"
        [ describe "light" (themeTests Theme.light)
        , describe "dark" (themeTests (Theme.forMode Theme.Dark))
        ]


themeTests : Theme -> List Test
themeTests theme =
    [ text "primary fill" theme.brandBlueOn theme.brandBlue
    , text "accent on card" theme.brandBlue theme.cardBg
    , text "accent on page" theme.brandBlue theme.pageBg
    , text "accent on soft" theme.brandBlue theme.brandBlueSoft
    , ui "focus ring on card" theme.focusRing theme.cardBg
    , text "danger fill" theme.dangerSolidOn theme.dangerSolid
    , text "danger hover fill" theme.dangerSolidOn theme.dangerSolidPressed
    , text "selected chip" theme.chipSelectedFg theme.chipSelectedBg
    , text "danger banner" theme.dangerFg theme.dangerBg
    , text "muted on card" theme.textMuted theme.cardBg
    , text "status green" theme.statusGreen theme.statusActiveBg
    , text "status red" theme.statusRed theme.statusDisabledBg
    ]


text : String -> Color -> Color -> Test
text label foreground background =
    expectContrast label minTextContrast foreground background


ui : String -> Color -> Color -> Test
ui label foreground background =
    expectContrast label minUiContrast foreground background


expectContrast : String -> Float -> Color -> Color -> Test
expectContrast label threshold foreground background =
    test label <|
        \_ ->
            contrast foreground background
                |> Expect.atLeast threshold


contrast : Color -> Color -> Float
contrast a b =
    let
        luminanceA : Float
        luminanceA =
            relativeLuminance a

        luminanceB : Float
        luminanceB =
            relativeLuminance b
    in
    (max luminanceA luminanceB + 0.05) / (min luminanceA luminanceB + 0.05)


relativeLuminance : Color -> Float
relativeLuminance color =
    let
        { red, green, blue } =
            Element.toRgb color
    in
    (0.2126 * linearize red) + (0.7152 * linearize green) + (0.0722 * linearize blue)


linearize : Float -> Float
linearize channel =
    if channel <= 0.03928 then
        channel / 12.92

    else
        ((channel + 0.055) / 1.055) ^ 2.4
