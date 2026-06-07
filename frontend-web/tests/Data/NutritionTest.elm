module Data.NutritionTest exposing (tests)

import Data.Nutrition as Nutrition
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.Nutrition"
        [ test "parses valid amounts" <|
            \_ ->
                Nutrition.safeAmount "12.5"
                    |> Expect.within (Expect.Absolute 0.0001) 12.5
        , test "invalid amounts become zero" <|
            \_ ->
                Nutrition.safeAmount "nope"
                    |> Expect.equal 0
        , test "negative amounts become zero" <|
            \_ ->
                Nutrition.safeAmount "-1"
                    |> Expect.equal 0
        , test "missing nutrient amount returns zero" <|
            \_ ->
                Nutrition.nutrientAmount "FAT_G" nutrients
                    |> Expect.equal 0
        , test "calories are read from ENERGY_KCAL" <|
            \_ ->
                Nutrition.nutrientAmount "ENERGY_KCAL" nutrients
                    |> Expect.equal 120
        , test "macro totals and percentages use 4/4/9 kcal factors" <|
            \_ ->
                Nutrition.macroTotals [ { nutrients = macros } ]
                    |> (\totals ->
                            { protein = totals.protein
                            , carbs = totals.carbs
                            , fat = totals.fat
                            , proteinPct = round totals.proteinPct
                            , carbsPct = round totals.carbsPct
                            , fatPct = round totals.fatPct
                            }
                       )
                    |> Expect.equal
                        { protein = 10
                        , carbs = 20
                        , fat = 10
                        , proteinPct = 19
                        , carbsPct = 38
                        , fatPct = 43
                        }
        , test "grams unit returns amount unchanged" <|
            \_ ->
                Nutrition.servingGrams { amount = "125", unit = "g" } servings
                    |> Expect.equal (Just 125)
        , test "known serving unit converts amount to grams" <|
            \_ ->
                Nutrition.servingGrams { amount = "2", unit = "piece" } servings
                    |> Expect.equal (Just 100)
        , test "unknown serving unit returns Nothing" <|
            \_ ->
                Nutrition.servingGrams { amount = "1", unit = "cup" } servings
                    |> Expect.equal Nothing
        , test "nutrient scaling multiplies per-100g nutrients by grams over 100" <|
            \_ ->
                Nutrition.scalePer100g 50 per100g
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "60", unit = "kcal" } ]
        , test "quantity nutrient scaling uses serving definitions" <|
            \_ ->
                Nutrition.nutrientsForQuantity { amount = "2", unit = "piece" } servings per100g
                    |> Expect.equal
                        (Just [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ])
        , test "saved snapshot scaling requires matching units" <|
            \_ ->
                Nutrition.scaledSnapshotForQuantity
                    { amount = "2", unit = "serving" }
                    { amount = "3", unit = "serving" }
                    nutrients
                    |> Expect.equal
                        (Just [ { code = "ENERGY_KCAL", amount = "180", unit = "kcal" } ])
        , test "saved snapshot scaling rejects changed units" <|
            \_ ->
                Nutrition.scaledSnapshotForQuantity
                    { amount = "2", unit = "serving" }
                    { amount = "3", unit = "g" }
                    nutrients
                    |> Expect.equal Nothing
        , test "dominantMacro returns Nothing for empty nutrients" <|
            \_ ->
                Nutrition.dominantMacro []
                    |> Expect.equal Nothing
        , test "dominantMacro returns Nothing for zero macros" <|
            \_ ->
                Nutrition.dominantMacro []
                    |> Expect.equal Nothing
        , test "dominantMacro picks Protein when its calories lead" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "30", unit = "g" }
                    , { code = "CARBS_G", amount = "10", unit = "g" }
                    , { code = "FAT_G", amount = "5", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Protein)
        , test "dominantMacro picks Carbs when its calories lead" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "5", unit = "g" }
                    , { code = "CARBS_G", amount = "30", unit = "g" }
                    , { code = "FAT_G", amount = "10", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Carbs)
        , test "dominantMacro picks Fat when its calories lead" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "5", unit = "g" }
                    , { code = "CARBS_G", amount = "10", unit = "g" }
                    , { code = "FAT_G", amount = "20", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Fat)
        , test "dominantMacro tie-break Protein over Carbs when calorie-equal" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "20", unit = "g" }
                    , { code = "CARBS_G", amount = "20", unit = "g" }
                    , { code = "FAT_G", amount = "5", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Protein)
        , test "dominantMacro tie-break Protein over Fat when calorie-equal" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "18", unit = "g" }
                    , { code = "CARBS_G", amount = "5", unit = "g" }
                    , { code = "FAT_G", amount = "8", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Protein)
        , test "dominantMacro all-equal by calories defaults to Protein" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "9", unit = "g" }
                    , { code = "CARBS_G", amount = "9", unit = "g" }
                    , { code = "FAT_G", amount = "4", unit = "g" }
                    ]
                    |> Expect.equal (Just Nutrition.Protein)
        ]


nutrients : List Nutrition.NutrientAmount
nutrients =
    [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]


macros : List Nutrition.NutrientAmount
macros =
    [ { code = "PROTEIN_G", amount = "10", unit = "g" }
    , { code = "CARBS_G", amount = "20", unit = "g" }
    , { code = "FAT_G", amount = "10", unit = "g" }
    ]


servings : List Nutrition.Serving
servings =
    [ { label = "Piece", quantity = "1", unit = "piece", grams = "50" } ]


per100g : List Nutrition.Per100gNutrient
per100g =
    [ { code = "ENERGY_KCAL", amountPer100g = "120", unit = "kcal" } ]
