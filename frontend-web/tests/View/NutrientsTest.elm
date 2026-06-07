module View.NutrientsTest exposing (tests)

{-| Tests for `View.Nutrients.nutrientLabel`. The label is a pure
`String -> String` function, so this file exercises:

  - the explicit lookup table (known backend codes), and
  - the generic parser fallback for unknown codes.

-}

import Expect
import Test exposing (Test, describe, test)
import View.Nutrients


tests : Test
tests =
    describe "View.Nutrients.nutrientLabel"
        [ knownCodes
        , genericFallback
        ]


assertCode : String -> String -> Expect.Expectation
assertCode code expected =
    View.Nutrients.nutrientLabel code
        |> Expect.equal expected


knownCodes : Test
knownCodes =
    describe "known backend codes"
        [ test "ENERGY_KCAL → Energy" <|
            \_ -> assertCode "ENERGY_KCAL" "Energy"
        , test "PROTEIN_G → Protein" <|
            \_ -> assertCode "PROTEIN_G" "Protein"
        , test "CARBS_G → Carbohydrates" <|
            \_ -> assertCode "CARBS_G" "Carbohydrates"
        , test "FAT_G → Fat" <|
            \_ -> assertCode "FAT_G" "Fat"
        , test "SATURATED_FAT_G → Saturated Fat" <|
            \_ -> assertCode "SATURATED_FAT_G" "Saturated Fat"
        , test "MONOUNSATURATED_FAT_G → Monounsaturated Fat" <|
            \_ -> assertCode "MONOUNSATURATED_FAT_G" "Monounsaturated Fat"
        , test "POLYUNSATURATED_FAT_G → Polyunsaturated Fat" <|
            \_ -> assertCode "POLYUNSATURATED_FAT_G" "Polyunsaturated Fat"
        , test "TRANS_FAT_G → Trans Fat" <|
            \_ -> assertCode "TRANS_FAT_G" "Trans Fat"
        , test "MAGNESIUM_MG → Magnesium" <|
            \_ -> assertCode "MAGNESIUM_MG" "Magnesium"
        , test "ZINC_MG → Zinc" <|
            \_ -> assertCode "ZINC_MG" "Zinc"
        , test "PHOSPHORUS_MG → Phosphorus" <|
            \_ -> assertCode "PHOSPHORUS_MG" "Phosphorus"
        , test "VITAMIN_E_MG → Vitamin E" <|
            \_ -> assertCode "VITAMIN_E_MG" "Vitamin E"
        , test "VITAMIN_B6_MG → Vitamin B6" <|
            \_ -> assertCode "VITAMIN_B6_MG" "Vitamin B6"
        , test "VITAMIN_B12_UG → Vitamin B12" <|
            \_ -> assertCode "VITAMIN_B12_UG" "Vitamin B12"
        , test "FOLATE_UG → Folate" <|
            \_ -> assertCode "FOLATE_UG" "Folate"
        ]


genericFallback : Test
genericFallback =
    describe "generic parser fallback"
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
