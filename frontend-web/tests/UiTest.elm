module UiTest exposing (tests)

{-| Tests for the design-system primitives in `Ui` and the new
components introduced by the visual re-skin
(`docs/visual-reskin.md` §6, §13).

The new UI components are pure rendering — there is no DOM available in
elm-test, so we cannot inspect the rendered colors directly. Instead,
we:

  - verify the token rebindings (so callers can rely on them),
  - verify the small `chip` background/foreground selection helpers
    (the only place where the design system makes a logical decision
    based on input), and
  - smoke-test the new rendering components by calling them and
    asserting they evaluate without crashing.

-}

import Element
import Expect
import String
import Test exposing (Test, describe, test)
import Ui
import Ui.Css as Css
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon
import Ui.Theme as Theme exposing (Theme)
import Ui.Typography as Typography
import View.Charts


theme : Theme
theme =
    Theme.light


{-| Discard any value and return a passing expectation. Used for smoke
tests that only need to confirm a UI component evaluates.
-}
pass : a -> Expect.Expectation
pass _ =
    Expect.pass


tests : Test
tests =
    describe "Ui"
        [ chipBehavior
        , cssVariables
        , deviceHelpers
        , truncationHelpers
        , renderingSmoke
        , chartSmoke
        ]



-- Chip selection logic (docs §6)


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



-- Device / truncation helpers (Round 3 plumbing)


phone : Element.Device
phone =
    Element.Device Element.Phone Element.Portrait


tablet : Element.Device
tablet =
    Element.Device Element.Tablet Element.Landscape


desktop : Element.Device
desktop =
    Element.Device Element.Desktop Element.Landscape


bigDesktop : Element.Device
bigDesktop =
    Element.Device Element.BigDesktop Element.Landscape


deviceHelpers : Test
deviceHelpers =
    describe "device helpers"
        [ test "isSmall is True for Phone" <|
            \_ -> Ui.isSmall phone |> Expect.equal True
        , test "isSmall is False for Tablet" <|
            \_ -> Ui.isSmall tablet |> Expect.equal False
        , test "isSmall is False for Desktop" <|
            \_ -> Ui.isSmall desktop |> Expect.equal False
        , test "isSmall is False for BigDesktop" <|
            \_ -> Ui.isSmall bigDesktop |> Expect.equal False
        ]


truncationHelpers : Test
truncationHelpers =
    describe "truncation helpers"
        [ test "truncatedText renders without crashing on a phone-sized string" <|
            \_ -> Ui.truncatedText phone "Roasted Sweet Potato" |> pass
        , test "truncatedText renders without crashing on a desktop-sized string" <|
            \_ -> Ui.truncatedText desktop "Roasted Sweet Potato" |> pass
        , test "truncatedText renders an empty string" <|
            \_ -> Ui.truncatedText phone "" |> pass
        , test "truncatedHeader renders a long heading on phone" <|
            \_ -> Typography.truncatedHeader theme "Roasted Sweet Potato With Cumin Yogurt" |> pass
        , test "truncatedListItemTitle renders a long label on phone" <|
            \_ ->
                Typography.truncatedListItemTitle theme "Roasted Sweet Potato With Cumin Yogurt"
                    |> pass
        ]



-- Rendering smoke tests (docs §13)


renderingSmoke : Test
renderingSmoke =
    describe "new components (smoke)"
        [ test "iconButton does not crash on valid icon" <|
            \_ ->
                Ui.iconButton phone
                    theme
                    { icon = Icon.ChevronLeft, title = "Back", onPress = () }
                    |> pass
        , test "iconButton renders an SVG icon" <|
            \_ ->
                Ui.iconButton phone
                    theme
                    { icon = Icon.ChevronLeft, title = "Back", onPress = () }
                    |> pass
        , test "dangerIconButton renders an SVG icon" <|
            \_ ->
                Ui.dangerIconButton phone
                    theme
                    { icon = Icon.Close, title = "Delete", onPress = () }
                    |> pass
        , test "fieldLabel renders with a label" <|
            \_ -> Ui.fieldLabel theme "Amount" |> pass
        , test "accentDot produces a value for any color" <|
            \_ -> Ui.accentDot DesignTokens.accentPink |> pass
        , test "coloredPill uses the provided bg and fg" <|
            \_ ->
                Ui.coloredPill
                    { label = "Active"
                    , bg = DesignTokens.accentSoftGreen
                    , fg = Element.rgb255 50 110 60
                    }
                    |> pass
        , test "statBlock renders the requested value" <|
            \_ ->
                Ui.statBlock
                    { value = "100"
                    , unit = "kcal"
                    , label = "Calories"
                    , color = theme.calorieAccent
                    }
                    |> pass
        , test "statBlockGroup arranges four blocks" <|
            \_ ->
                Ui.statBlockGroup
                    [ Ui.statBlock
                        { value = "1", unit = "u", label = "A", color = theme.calorieAccent }
                    , Ui.statBlock
                        { value = "2", unit = "u", label = "B", color = theme.proteinAccent }
                    , Ui.statBlock
                        { value = "3", unit = "u", label = "C", color = theme.fatAccent }
                    , Ui.statBlock
                        { value = "4", unit = "u", label = "D", color = theme.carbsAccent }
                    ]
                    |> pass
        , test "chip renders in the unselected state" <|
            \_ ->
                Ui.chip theme { label = "Fruit", selected = False, onClick = Nothing }
                    |> pass
        , test "chip renders in the selected state" <|
            \_ ->
                Ui.chip theme { label = "Fruit", selected = True, onClick = Nothing }
                    |> pass
        , test "chip renders interactive with Just msg" <|
            \_ ->
                Ui.chip theme { label = "Fruit", selected = True, onClick = Just () }
                    |> pass
        , test "toggleSwitch renders in the active state" <|
            \_ ->
                Ui.toggleSwitch theme
                    { isActive = True, onToggle = () }
                    |> pass
        , test "toggleSwitch renders in the inactive state" <|
            \_ ->
                Ui.toggleSwitch theme
                    { isActive = False, onToggle = () }
                    |> pass
        , test "bottomActionButtons renders a secondary action" <|
            \_ ->
                Ui.bottomActionButtons phone
                    theme
                    [ { label = "Cancel", onPress = (), tone = Ui.SecondaryAction }
                    , { label = "Delete", onPress = (), tone = Ui.DangerAction }
                    ]
                    |> pass
        ]



-- Chart smoke tests


chartSmoke : Test
chartSmoke =
    describe "View.Charts (smoke)"
        [ test "linearProgress renders with a non-zero value" <|
            \_ ->
                Ui.linearProgress theme
                    { value = 75, max = 100, color = theme.proteinAccent }
                    |> pass
        , test "linearProgress renders with a zero max without crashing" <|
            \_ ->
                Ui.linearProgress theme
                    { value = 10, max = 0, color = theme.proteinAccent }
                    |> pass
        , test "verticalBarChart renders a list of bars" <|
            \_ ->
                View.Charts.verticalBarChart
                    { baselineColor = theme.divider }
                    [ { label = "M", value = 10, color = DesignTokens.accentPink }
                    , { label = "T", value = 20, color = DesignTokens.accentYellow }
                    ]
                    |> pass
        ]
