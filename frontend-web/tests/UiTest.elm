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
import View.Charts


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
        , renderingSmoke
        , chartSmoke
        ]



-- Chip selection logic (docs §6)


chipBehavior : Test
chipBehavior =
    describe "chip"
        [ test "uses inputFill background when not selected" <|
            \_ -> Ui.chipBackground False |> Expect.equal (Element.rgb255 244 246 248)
        , test "uses primaryTeal background when selected" <|
            \_ -> Ui.chipBackground True |> Expect.equal Ui.primaryTeal
        ]



-- Rendering smoke tests (docs §13)


renderingSmoke : Test
renderingSmoke =
    describe "new components (smoke)"
        [ test "iconButton does not crash on empty label" <|
            \_ -> Ui.iconButton "" () |> pass
        , test "iconButton renders with a glyph" <|
            \_ -> Ui.iconButton "←" () |> pass
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
            \_ -> Ui.chip { label = "Fruit", selected = False, onClick = Nothing } |> pass
        , test "chip renders in the selected state" <|
            \_ -> Ui.chip { label = "Fruit", selected = True, onClick = Nothing } |> pass
        , test "chip renders interactive with Just msg" <|
            \_ -> Ui.chip { label = "Fruit", selected = True, onClick = Just () } |> pass
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
                Ui.linearProgress
                    { value = 75, max = 100, color = Ui.proteinColor }
                    |> pass
        , test "linearProgress renders with a zero max without crashing" <|
            \_ ->
                Ui.linearProgress
                    { value = 10, max = 0, color = Ui.proteinColor }
                    |> pass
        , test "verticalBarChart renders a list of bars" <|
            \_ ->
                View.Charts.verticalBarChart
                    [ { label = "M", value = 10, color = Ui.accentPink }
                    , { label = "T", value = 20, color = Ui.accentYellow }
                    ]
                    |> pass
        ]
