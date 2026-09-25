module Data.NutritionTest exposing (tests)

import Data.Nutrition as Nutrition
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.Nutrition"
        [ test "safeAmount parses valid amounts and zeroes invalid or negative input" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Nutrition.safeAmount "12.5"
                            |> Expect.within (Expect.Absolute 0.0001) 12.5
                    , \_ -> Nutrition.safeAmount "nope" |> Expect.equal 0
                    , \_ -> Nutrition.safeAmount "-1" |> Expect.equal 0
                    ]
                    ()
        , test "nutrientAmount reads present codes and zeroes missing ones" <|
            \_ ->
                Expect.all
                    [ \_ -> Nutrition.nutrientAmount "FAT_G" nutrients |> Expect.equal 0
                    , \_ ->
                        Nutrition.nutrientAmount "ENERGY_KCAL" nutrients
                            |> Expect.equal 120
                    ]
                    ()
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
        , test "servingGrams converts known units and rejects unknown units" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Nutrition.servingGrams { amount = "125", unit = "g" } servings
                            |> Expect.equal (Just 125)
                    , \_ ->
                        Nutrition.servingGrams { amount = "2", unit = "piece" } servings
                            |> Expect.equal (Just 100)
                    , \_ ->
                        Nutrition.servingGrams { amount = "1", unit = "cup" } servings
                            |> Expect.equal Nothing
                    ]
                    ()
        , test "nutrient scaling multiplies per-100g nutrients by grams over 100" <|
            \_ ->
                Nutrition.scalePer100g 50 per100g
                    |> Expect.equal [ { code = "ENERGY_KCAL", amount = "60", unit = "kcal" } ]
        , test "quantity nutrient scaling uses serving definitions" <|
            \_ ->
                Nutrition.nutrientsForQuantity { amount = "2", unit = "piece" } servings per100g
                    |> Expect.equal
                        (Just [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ])
        , test "scaledSnapshotForQuantity scales matching units and rejects changed units" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Nutrition.scaledSnapshotForQuantity
                            { amount = "2", unit = "serving" }
                            { amount = "3", unit = "serving" }
                            nutrients
                            |> Expect.equal
                                (Just [ { code = "ENERGY_KCAL", amount = "180", unit = "kcal" } ])
                    , \_ ->
                        Nutrition.scaledSnapshotForQuantity
                            { amount = "2", unit = "serving" }
                            { amount = "3", unit = "g" }
                            nutrients
                            |> Expect.equal Nothing
                    ]
                    ()
        , test "dominantMacro returns Nothing for zero macros" <|
            \_ ->
                Nutrition.dominantMacro
                    [ { code = "PROTEIN_G", amount = "0", unit = "g" }
                    , { code = "CARBS_G", amount = "0", unit = "g" }
                    , { code = "FAT_G", amount = "0", unit = "g" }
                    ]
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


servings : List { unit : String, gramsPerUnit : String }
servings =
    [ { unit = "piece", gramsPerUnit = "50" } ]


per100g : List { code : String, amountPer100g : String, unit : String }
per100g =
    [ { code = "ENERGY_KCAL", amountPer100g = "120", unit = "kcal" } ]
