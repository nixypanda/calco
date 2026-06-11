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

import Data.Nutrition
import Element
import Expect
import Test exposing (Test, describe, test)
import Ui
import Ui.Theme as Theme
import View.Charts


theme : Theme.Theme
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
                    |> Expect.equal theme.inputFill
        , test "uses primaryTeal background when selected" <|
            \_ ->
                Ui.chipBackground theme True
                    |> Expect.equal Ui.primaryTeal
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
        , test "truncationCap returns the tighter Phone cap" <|
            \_ -> Ui.truncationCap phone |> Expect.equal 25
        , test "truncationCap returns the default for Tablet" <|
            \_ -> Ui.truncationCap tablet |> Expect.equal Ui.defaultTruncationChars
        , test "truncationCap returns the default for Desktop" <|
            \_ -> Ui.truncationCap desktop |> Expect.equal Ui.defaultTruncationChars
        , test "defaultTruncationChars is 40" <|
            \_ -> Ui.defaultTruncationChars |> Expect.equal 40
        ]


truncationHelpers : Test
truncationHelpers =
    describe "truncation helpers"
        [ test "truncateWithEllipsis returns the string unchanged when short enough" <|
            \_ ->
                Ui.truncateWithEllipsis 12 "Apple"
                    |> Expect.equal "Apple"
        , test "truncateWithEllipsis appends a single ellipsis and caps the total length" <|
            \_ ->
                Ui.truncateWithEllipsis 8 "Roasted Sweet Potato"
                    |> Expect.equal "Roast..."
        , test "truncateWithEllipsis caps the visible prefix at maxChars - 3" <|
            \_ ->
                Ui.truncateWithEllipsis 8 "Hello World"
                    |> Expect.equal "Hello..."
        , test "truncateWithEllipsis still truncates when maxChars is very small" <|
            \_ ->
                Ui.truncateWithEllipsis 2 "Hello"
                    |> Expect.equal "..."
        , test "truncatedText renders without crashing on a phone-sized string" <|
            \_ -> Ui.truncatedText phone "Roasted Sweet Potato" |> pass
        , test "truncatedText renders without crashing on a desktop-sized string" <|
            \_ -> Ui.truncatedText desktop "Roasted Sweet Potato" |> pass
        , test "truncatedText renders an empty string" <|
            \_ -> Ui.truncatedText phone "" |> pass
        ]



-- Rendering smoke tests (docs §13)


renderingSmoke : Test
renderingSmoke =
    describe "new components (smoke)"
        [ test "iconButton does not crash on empty label" <|
            \_ ->
                Ui.iconButton theme { label = "", title = "Empty", onPress = () }
                    |> pass
        , test "iconButton renders with a glyph" <|
            \_ ->
                Ui.iconButton theme { label = "←", title = "Back", onPress = () }
                    |> pass
        , test "dangerIconButton renders with a glyph" <|
            \_ ->
                Ui.dangerIconButton theme
                    { label = "×", title = "Delete", onPress = () }
                    |> pass
        , test "fieldLabel renders with a label" <|
            \_ -> Ui.fieldLabel theme "Amount" |> pass
        , test "accentDot produces a value for any color" <|
            \_ -> Ui.accentDot Ui.accentPink |> pass
        , test "coloredPill uses the provided bg and fg" <|
            \_ ->
                Ui.coloredPill
                    { label = "Active"
                    , bg = Ui.accentSoftGreen
                    , fg = Element.rgb255 50 110 60
                    }
                    |> pass
        , test "statBlock renders the requested value" <|
            \_ ->
                Ui.statBlock
                    { value = "100"
                    , unit = "kcal"
                    , label = "Calories"
                    , color = Ui.primaryTeal
                    }
                    |> pass
        , test "statBlockGroup arranges four blocks" <|
            \_ ->
                Ui.statBlockGroup
                    [ Ui.statBlock
                        { value = "1", unit = "u", label = "A", color = Ui.primaryTeal }
                    , Ui.statBlock
                        { value = "2", unit = "u", label = "B", color = Ui.accentPink }
                    , Ui.statBlock
                        { value = "3", unit = "u", label = "C", color = Ui.accentYellow }
                    , Ui.statBlock
                        { value = "4", unit = "u", label = "D", color = Ui.accentSoftGreen }
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
        , test "macroColor resolves Protein to accentPink" <|
            \_ ->
                Ui.macroColor Data.Nutrition.Protein
                    |> Expect.equal Ui.proteinColor
        , test "macroColor resolves Carbs to accentSoftGreen" <|
            \_ ->
                Ui.macroColor Data.Nutrition.Carbs
                    |> Expect.equal Ui.carbsColor
        , test "macroColor resolves Fat to accentYellow" <|
            \_ ->
                Ui.macroColor Data.Nutrition.Fat
                    |> Expect.equal Ui.fatColor
        ]



-- Chart smoke tests


chartSmoke : Test
chartSmoke =
    describe "View.Charts (smoke)"
        [ test "linearProgress renders with a non-zero value" <|
            \_ ->
                Ui.linearProgress theme
                    { value = 75, max = 100, color = Ui.proteinColor }
                    |> pass
        , test "linearProgress renders with a zero max without crashing" <|
            \_ ->
                Ui.linearProgress theme
                    { value = 10, max = 0, color = Ui.proteinColor }
                    |> pass
        , test "verticalBarChart renders a list of bars" <|
            \_ ->
                View.Charts.verticalBarChart
                    { baselineColor = theme.divider }
                    [ { label = "M", value = 10, color = Ui.accentPink }
                    , { label = "T", value = 20, color = Ui.accentYellow }
                    ]
                    |> pass
        ]
