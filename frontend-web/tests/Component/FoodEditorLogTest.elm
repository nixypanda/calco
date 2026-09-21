module Component.FoodEditorLogTest exposing (tests)

import Api.Foods exposing (NutrientItem)
import Component.FoodEditor as Editor
import Data.FoodAssistant exposing (FoodDraft, SuggestedLog)
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.Theme as Theme


tests : Test
tests =
    describe "Component.FoodEditor food-log mode"
        [ test "accepts zero values for all required nutrients" <|
            \_ ->
                Editor.validateLog
                    { validForm
                        | nutrients =
                            List.map
                                (\row -> { row | amount = "0" })
                                validForm.nutrients
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
                Editor.validateLog
                    { validForm
                        | nutrients = setAmount "PROTEIN_G" "-1" validForm.nutrients
                    }
                    |> Expect.equal (Err "Protein must be zero or greater.")
        , test "accepts optional catalog nutrients" <|
            \_ ->
                Editor.validateLog
                    { validForm
                        | nutrients =
                            validForm.nutrients
                                ++ [ { code = "FIBER_G"
                                     , amount = "7"
                                     , unit = "g"
                                     }
                                   ]
                    }
                    |> Result.map (List.map .code << .nutrients)
                    |> Expect.equal
                        (Ok [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G" ])
        , test "rejects duplicate nutrients" <|
            \_ ->
                Editor.validateLog
                    { validForm
                        | nutrients =
                            validForm.nutrients
                                ++ [ { code = "FAT_G"
                                     , amount = "1"
                                     , unit = "g"
                                     }
                                   ]
                    }
                    |> Expect.equal (Err "Each nutrient can only be added once.")
        , test "does not require weight for an ad-hoc-only log" <|
            \_ ->
                Editor.validateLog validForm
                    |> Result.map .portionWeight
                    |> Expect.equal (Ok Nothing)
        , test "requires positive weight when saving a custom food" <|
            \_ ->
                validForm
                    |> update Editor.LogPersistenceToggled
                    |> update (Editor.PortionWeightChanged "0")
                    |> Editor.validateLog
                    |> Expect.equal
                        (Err "Weight of this logged portion must be greater than zero.")
        , test "derives per-100-g nutrients and grams per unit" <|
            \_ ->
                validForm
                    |> update (Editor.LogQuantityChanged "2")
                    |> update (Editor.LogUnitChanged "piece")
                    |> update Editor.LogPersistenceToggled
                    |> update (Editor.PortionWeightChanged "160")
                    |> (\form ->
                            { form
                                | nutrients =
                                    setAmount "ENERGY_KCAL" "400" form.nutrients
                            }
                       )
                    |> Editor.toCustomFoodFromLogRequest
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
        , test "log-only view hides reusable-food fields" <|
            \_ ->
                Editor.viewForLog
                    { theme = Theme.light, device = phone, language = Util.EN_US }
                    Editor.AllNutrients
                    []
                    []
                    validForm
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Logged Portion" ]
                        , Query.has [ Selector.text "Portion Nutrition" ]
                        , Query.has [ Selector.text "Log Details" ]
                        , Query.hasNot [ Selector.text "Categories" ]
                        , Query.hasNot [ Selector.text "Servings" ]
                        ]
        , test "save-and-log view reveals reusable-food fields" <|
            \_ ->
                validForm
                    |> update Editor.LogPersistenceToggled
                    |> Editor.viewForLog
                        { theme = Theme.light, device = phone, language = Util.EN_US }
                        Editor.AllNutrients
                        []
                        []
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "Categories" ]
                        , Query.has [ Selector.text "Servings" ]
                        , Query.has
                            [ Selector.text "Weight of this logged portion (g)" ]
                        ]
        , test "converts per-100-g nutrition into logged-portion totals" <|
            \_ ->
                Editor.applyAiLogDraft catalog
                    draft
                    suggested
                    (Editor.emptyLogForm Nothing Nothing)
                    |> Result.map
                        (\form ->
                            ( Editor.foodLogFields form |> Maybe.map .quantity
                            , Editor.logPortionWeight form
                            , List.map .amount form.nutrients
                            )
                        )
                    |> Expect.equal
                        (Ok ( Just "1", Just "250", [ "500", "25", "50", "30" ] ))
        , test "AI log quantity edits scale weight and every nutrient total" <|
            \_ ->
                Editor.applyAiLogDraft catalog
                    draft
                    suggested
                    (Editor.emptyLogForm Nothing Nothing)
                    |> Result.map (Editor.changeLogQuantity "2")
                    |> Result.map
                        (\form ->
                            ( Editor.logPortionWeight form
                            , List.map .amount form.nutrients
                            )
                        )
                    |> Expect.equal
                        (Ok ( Just "500", [ "1000", "50", "100", "60" ] ))
        , test "AI log serving changes use their gram conversion" <|
            \_ ->
                Editor.applyAiLogDraft catalog
                    draft
                    suggested
                    (Editor.emptyLogForm Nothing Nothing)
                    |> Result.map (Editor.changeLogUnit draft "piece")
                    |> Result.map
                        (\form ->
                            ( Editor.foodLogFields form |> Maybe.map .unit
                            , Editor.logPortionWeight form
                            , List.map .amount form.nutrients
                            )
                        )
                    |> Expect.equal
                        (Ok ( Just "piece", Just "125", [ "250", "12.5", "25", "15" ] ))
        ]


validForm : Editor.FormModel
validForm =
    let
        form : Editor.FormModel
        form =
            Editor.emptyLogForm (Just "2026-09-14") Nothing
    in
    { form
        | name = "Paneer wrap"
        , nutrients =
            [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
            , { code = "PROTEIN_G", amount = "24", unit = "g" }
            , { code = "CARBS_G", amount = "48", unit = "g" }
            , { code = "FAT_G", amount = "25", unit = "g" }
            ]
    }


update : Editor.Msg -> Editor.FormModel -> Editor.FormModel
update msg form =
    Editor.update msg form |> first


setAmount : String -> String -> List Editor.NutrientRow -> List Editor.NutrientRow
setAmount code value =
    List.map
        (\row ->
            if row.code == code then
                { row | amount = value }

            else
                row
        )


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


phone : Element.Device
phone =
    { class = Phone, orientation = Portrait }


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
