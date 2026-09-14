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
                        | calories = "0"
                        , protein = "0"
                        , carbohydrates = "0"
                        , fat = "0"
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
                Form.validate { validForm | protein = "-1" }
                    |> Expect.equal (Err "Protein must be zero or greater.")
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
                        , calories = "400"
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
    , calories = "520"
    , protein = "24"
    , carbohydrates = "48"
    , fat = "25"
    , notes = ""
    , saveToMyFoods = False
    , portionWeight = ""
    }
