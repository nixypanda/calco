module Page.FoodLog.AdHocFormTest exposing (tests)

import Expect
import Page.FoodLog.AdHocForm as Form
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.AdHocForm"
        [ test "accepts zero values for all required nutrients" <|
            \_ ->
                Form.validate
                    { validForm
                        | nutrients = List.map (\row -> { row | amount = "0" }) validForm.nutrients
                    }
                    |> Result.map .nutrientTotals
                    |> Expect.equal
                        (Ok
                            [ ( "ENERGY_KCAL", 0 )
                            , ( "PROTEIN_G", 0 )
                            , ( "CARBS_G", 0 )
                            , ( "FAT_G", 0 )
                            ]
                        )
        , test "rejects a negative nutrient" <|
            \_ ->
                Form.validate
                    { validForm
                        | nutrients = setAmount "PROTEIN_G" "-1" validForm.nutrients
                    }
                    |> Expect.equal (Err "Protein must be zero or greater.")
        , test "accepts optional catalog nutrients" <|
            \_ ->
                Form.validate
                    { validForm
                        | nutrients =
                            validForm.nutrients
                                ++ [ { code = "FIBER_G", amount = "7", unit = "g" } ]
                    }
                    |> Result.map (List.map .code << .nutrients)
                    |> Expect.equal
                        (Ok [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G" ])
        , test "rejects duplicate nutrients" <|
            \_ ->
                Form.validate
                    { validForm
                        | nutrients =
                            validForm.nutrients
                                ++ [ { code = "FAT_G", amount = "1", unit = "g" } ]
                    }
                    |> Expect.equal (Err "Each nutrient can only be added once.")
        , test "does not require weight when saving is off" <|
            \_ ->
                Form.validate { validForm | portionWeight = "" }
                    |> Result.map .portionWeight
                    |> Expect.equal (Ok Nothing)
        , test "requires positive weight when saving is on" <|
            \_ ->
                Form.validate
                    { validForm
                        | saveToMyFoods = True
                        , portionWeight = "0"
                    }
                    |> Expect.equal
                        (Err "Weight of this logged portion must be greater than zero.")
        , test "derives per-100-g nutrients and grams per unit" <|
            \_ ->
                Form.validate
                    { validForm
                        | amount = "2"
                        , unit = "piece"
                        , nutrients = setAmount "ENERGY_KCAL" "400" validForm.nutrients
                        , portionWeight = "160"
                        , saveToMyFoods = True
                    }
                    |> Result.andThen Form.toCustomFoodRequest
                    |> Result.map
                        (\request ->
                            { amountPer100g =
                                request.nutrients |> List.head |> Maybe.map .amountPer100g
                            , gramsPerUnit =
                                request.servings |> List.head |> Maybe.map .gramsPerUnit
                            , defaultQuantity = request.defaultQuantity
                            , defaultUnit = request.defaultUnit
                            }
                        )
                    |> Expect.equal
                        (Ok
                            { amountPer100g = Just 250
                            , gramsPerUnit = Just 80
                            , defaultQuantity = Just "2"
                            , defaultUnit = Just "piece"
                            }
                        )
        ]


validForm : Form.Model
validForm =
    { date = "2026-09-14"
    , mealSlot = Nothing
    , name = "Paneer wrap"
    , brand = ""
    , amount = "1"
    , unit = "serving"
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
        , { code = "PROTEIN_G", amount = "24", unit = "g" }
        , { code = "CARBS_G", amount = "48", unit = "g" }
        , { code = "FAT_G", amount = "25", unit = "g" }
        ]
    , notes = ""
    , saveToMyFoods = False
    , portionWeight = ""
    }


setAmount : String -> String -> List Form.NutrientRow -> List Form.NutrientRow
setAmount code value =
    List.map
        (\row ->
            if row.code == code then
                { row | amount = value }

            else
                row
        )
