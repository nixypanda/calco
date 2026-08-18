module View.NutrientsTest exposing (tests)

{-| Tests for `View.Nutrients.nutrientLabel`.

Only the generic parser is covered: the curated code-to-label table is
data, and asserting its entries back would just restate the source.

-}

import Expect
import Test exposing (Test, describe, test)
import View.Nutrients


tests : Test
tests =
    describe "View.Nutrients"
        [ genericFallback
        ]


assertCode : String -> String -> Expect.Expectation
assertCode code expected =
    View.Nutrients.nutrientLabel code
        |> Expect.equal expected


genericFallback : Test
genericFallback =
    describe "nutrientLabel generic parser fallback"
        [ test "single-word _MG code → 'Riboflavin (mg)'" <|
            \_ -> assertCode "RIBOFLAVIN_MG" "Riboflavin (mg)"
        , test "multi-word _UG code → 'Beta Carotene (ug)'" <|
            \_ -> assertCode "BETA_CAROTENE_UG" "Beta Carotene (ug)"
        , test "single-word _G code → 'Lycopene (g)'" <|
            \_ -> assertCode "LYCOPENE_G" "Lycopene (g)"
        , test "_KCAL suffix falls back to unit 'kcal'" <|
            \_ -> assertCode "BETA_CAROTENE_KCAL" "Beta Carotene (kcal)"
        , test "code with no recognized unit falls back to title-cased code" <|
            \_ -> assertCode "BETA_CAROTENE" "Beta Carotene"
        , test "bare unknown single-word code is title-cased" <|
            \_ -> assertCode "MYSTERY" "Mystery"
        , test "case-insensitive unit suffix" <|
            \_ -> assertCode "riboflavin_mg" "Riboflavin (mg)"
        ]
