module Page.FoodLog.AiReviewTest exposing (tests)

import Api.Foods exposing (NutrientItem)
import Data.FoodAssistant exposing (FoodDraft, SuggestedLog)
import Expect
import Page.FoodLog.AdHocForm as AdHocForm
import Page.FoodLog.AiReview as AiReview
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.AiReview"
        [ test "converts per-100-g nutrition into logged-portion totals" <|
            \_ ->
                AiReview.fromDraft catalog draft suggested (AdHocForm.empty Nothing Nothing)
                    |> Result.map
                        (\form ->
                            ( form.amount
                            , form.portionWeight
                            , List.map .amount form.nutrients
                            )
                        )
                    |> Expect.equal
                        (Ok ( "1", "250", [ "500", "25", "50", "30" ] ))
        , test "quantity edits scale weight and every nutrient total" <|
            \_ ->
                AiReview.fromDraft catalog draft suggested (AdHocForm.empty Nothing Nothing)
                    |> Result.map (AiReview.changeAmount "2")
                    |> Result.map
                        (\form ->
                            ( form.portionWeight, List.map .amount form.nutrients )
                        )
                    |> Expect.equal
                        (Ok ( "500", [ "1000", "50", "100", "60" ] ))
        , test "known serving changes use their gram conversion" <|
            \_ ->
                AiReview.fromDraft catalog draft suggested (AdHocForm.empty Nothing Nothing)
                    |> Result.map (AiReview.changeUnit draft "piece")
                    |> Result.map
                        (\form ->
                            ( form.unit, form.portionWeight, List.map .amount form.nutrients )
                        )
                    |> Expect.equal
                        (Ok ( "piece", "125", [ "250", "12.5", "25", "15" ] ))
        ]


catalog : List NutrientItem
catalog =
    [ nutrient "ENERGY_KCAL" "Calories" "kcal"
    , nutrient "PROTEIN_G" "Protein" "g"
    , nutrient "CARBS_G" "Carbohydrates" "g"
    , nutrient "FAT_G" "Fat" "g"
    ]


nutrient : String -> String -> String -> NutrientItem
nutrient code name unit =
    { code = code, name = name, unit = unit, category = "Core" }


draft : FoodDraft
draft =
    { name = "Paneer wrap"
    , brand = Nothing
    , categories = [ "wrap" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "serving"
    , nutrients =
        [ { code = "ENERGY_KCAL", amountPer100g = "200" }
        , { code = "PROTEIN_G", amountPer100g = "10" }
        , { code = "CARBS_G", amountPer100g = "20" }
        , { code = "FAT_G", amountPer100g = "12" }
        ]
    , servings =
        [ { unit = "serving", gramsPerUnit = "250" }
        , { unit = "piece", gramsPerUnit = "125" }
        ]
    }


suggested : SuggestedLog
suggested =
    { amount = "1", unit = "serving", totalWeightGrams = "250" }
