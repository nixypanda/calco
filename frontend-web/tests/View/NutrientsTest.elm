module View.NutrientsTest exposing (tests)

{-| Tests for `View.Nutrients.nutrientLabel`.

Only the generic parser is covered: the curated code-to-label table is
data, and asserting its entries back would just restate the source.

-}

import Expect
import Test exposing (Test, describe, test)
import Translations.Util as Util
import View.Nutrients


tests : Test
tests =
    describe "View.Nutrients"
        [ genericFallback
        ]


assertCode : String -> String -> Expect.Expectation
assertCode code expected =
    View.Nutrients.nutrientLabel Util.EN_US code
        |> Expect.equal expected


genericFallback : Test
genericFallback =
    describe "nutrientLabel generic parser fallback"
        [ test "derives a title-cased label and unit from the nutrient code" <|
            \_ ->
                Expect.all
                    [ \_ -> assertCode "RIBOFLAVIN_MG" "Riboflavin (mg)"
                    , \_ -> assertCode "BETA_CAROTENE_UG" "Beta Carotene (ug)"
                    , \_ -> assertCode "LYCOPENE_G" "Lycopene (g)"
                    , \_ -> assertCode "BETA_CAROTENE_KCAL" "Beta Carotene (kcal)"
                    , \_ -> assertCode "BETA_CAROTENE" "Beta Carotene"
                    , \_ -> assertCode "riboflavin_mg" "Riboflavin (mg)"
                    ]
                    ()
        ]
