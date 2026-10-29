module Component.FoodEditorLogTest exposing (tests)

import Api.Foods exposing (NutrientItem)
import Component.FoodEditor as Editor
    exposing
        ( FormModel
        , LogPersistence(..)
        , NutrientRow
        , PortionNutrition(..)
        )
import Data.FoodAssistant exposing (FoodDraft, SuggestedLog)
import Expect
import Fuzz
import I18n
import Lib.Date as LocalDate
import Test exposing (Test, describe, fuzz2, fuzz3, test)
import Translations.Ids exposing (TranslationId(..))
import View.Nutrients as Nutrients


tests : Test
tests =
    describe "Component.FoodEditor food-log mode"
        [ validateLogBranches
        , customFoodFromLogScaling
        , aiDraftScaling
        , quantityScaling
        , unitScaling
        ]


validateLogBranches : Test
validateLogBranches =
    test "log validation rejects negative and duplicate nutrients and a zero portion" <|
        \_ ->
            let
                form : FormModel
                form =
                    logForm basePortion IndependentPortion LogAdHocOnly coreNutrients

                negative : FormModel
                negative =
                    { form
                        | nutrients =
                            setAmount "PROTEIN_G" "-1" form.nutrients
                    }

                duplicate : FormModel
                duplicate =
                    { form
                        | nutrients =
                            coreNutrients ++ [ { code = "FAT_G", amount = "1", unit = "g" } ]
                    }

                zeroWeight : FormModel
                zeroWeight =
                    logForm basePortion
                        IndependentPortion
                        (SaveCustomFoodThenLog { portionWeight = "0" })
                        coreNutrients

                expectedNegative : String
                expectedNegative =
                    I18n.en
                        (TidFoodEditorErrorZeroOrGreater
                            (Nutrients.nutrientLabel I18n.defaultLanguage "PROTEIN_G")
                        )

                expectedWeight : String
                expectedWeight =
                    I18n.en
                        (TidFoodEditorErrorGreaterThanZero
                            (I18n.en TidFoodEditorLabelPortionWeight)
                        )
            in
            Expect.all
                [ \_ ->
                    Editor.validateLog negative |> Expect.equal (Err expectedNegative)
                , \_ ->
                    Editor.validateLog duplicate
                        |> Expect.equal (Err (I18n.en TidFoodEditorErrorDuplicateNutrient))
                , \_ ->
                    Editor.validateLog zeroWeight |> Expect.equal (Err expectedWeight)
                ]
                ()


{-| Property: per-100-g values are the logged totals divided by the portion
weight and multiplied by 100; serving grams are weight divided by quantity.
-}
customFoodFromLogScaling : Test
customFoodFromLogScaling =
    fuzz3 (Fuzz.intRange 10 1000)
        (Fuzz.intRange 0 10000)
        (Fuzz.intRange 1 10)
        "custom food payload converts logged totals to per-100-g values"
    <|
        \weight amount quantity ->
            let
                form : FormModel
                form =
                    logForm
                        { date = "2026-09-14"
                        , quantity = String.fromInt quantity
                        , unit = "piece"
                        }
                        IndependentPortion
                        (SaveCustomFoodThenLog { portionWeight = String.fromInt weight })
                        (energyNutrients amount)

                expected :
                    Result
                        String
                        { amountPer100g : Maybe Float
                        , gramsPerUnit : Maybe Float
                        , defaultQuantity : Maybe String
                        , defaultUnit : Maybe String
                        }
                expected =
                    Ok
                        { amountPer100g = Just (toFloat amount * 100 / toFloat weight)
                        , gramsPerUnit = Just (toFloat weight / toFloat quantity)
                        , defaultQuantity = Just (String.fromInt quantity)
                        , defaultUnit = Just "piece"
                        }
            in
            Editor.toCustomFoodFromLogRequest form
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
                |> Expect.equal expected


{-| Property: the AI draft's per-100-g amounts become logged-portion totals,
using the suggested weight for every nutrient row.
-}
aiDraftScaling : Test
aiDraftScaling =
    fuzz2 (Fuzz.intRange 1 1000)
        (Fuzz.intRange 0 10000)
        "AI per-100-g values scale to the suggested portion"
    <|
        \weight amount ->
            let
                expected : Float
                expected =
                    toFloat amount * toFloat weight / 100

                suggested : SuggestedLog
                suggested =
                    { amount = "1"
                    , unit = "serving"
                    , totalWeightGrams = String.fromInt weight
                    }
            in
            Editor.applyAiLogDraft catalog
                (aiDraft (String.fromInt amount))
                suggested
                (logForm basePortion IndependentPortion LogAdHocOnly coreNutrients)
                |> Result.map
                    (\form ->
                        { totals = nutrientAmounts form
                        , weight =
                            Editor.logPortionWeight form |> Maybe.andThen String.toFloat
                        , fields =
                            Editor.foodLogFields form
                                |> Maybe.map (\fields -> ( fields.quantity, fields.unit ))
                        }
                    )
                |> expectApplied
                    { totals = List.repeat 4 expected
                    , weight = Just (toFloat weight)
                    , fields = Just ( "1", "serving" )
                    }


{-| Property: changing the quantity scales the derived weight and every
nutrient total by new quantity / old quantity.
-}
quantityScaling : Test
quantityScaling =
    fuzz2 (Fuzz.intRange 1 10)
        (Fuzz.intRange 1 10)
        "changing the log quantity scales the portion and nutrient totals"
    <|
        \oldQuantity newQuantity ->
            let
                base : Result String FormModel
                base =
                    Editor.applyAiLogDraft catalog
                        (aiDraft "200")
                        { amount = String.fromInt oldQuantity
                        , unit = "serving"
                        , totalWeightGrams = "250"
                        }
                        (logForm basePortion IndependentPortion LogAdHocOnly coreNutrients)

                ratio : Float
                ratio =
                    toFloat newQuantity / toFloat oldQuantity
            in
            case base of
                Err message ->
                    Expect.fail message

                Ok baseForm ->
                    baseForm
                        |> Editor.changeLogQuantity (String.fromInt newQuantity)
                        |> (\form ->
                                { totals = nutrientAmounts form
                                , weight =
                                    Editor.logPortionWeight form |> Maybe.andThen String.toFloat
                                , fields =
                                    Editor.foodLogFields form |> Maybe.map .quantity
                                }
                           )
                        |> Ok
                        |> expectApplied
                            { totals =
                                nutrientAmounts baseForm |> List.map ((*) ratio)
                            , weight = Just (250 * ratio)
                            , fields = Just (String.fromInt newQuantity)
                            }


{-| Property: switching units uses the new serving's gram conversion and
rescales the weight and nutrient totals to the same portion.
-}
unitScaling : Test
unitScaling =
    fuzz2 (Fuzz.intRange 1 10)
        (Fuzz.intRange 1 500)
        "changing the log unit uses the serving gram conversion"
    <|
        \quantity pieceGrams ->
            let
                draft : FoodDraft
                draft =
                    aiDraftWithPiece pieceGrams

                base : Result String FormModel
                base =
                    Editor.applyAiLogDraft catalog
                        draft
                        { amount = String.fromInt quantity
                        , unit = "serving"
                        , totalWeightGrams = "250"
                        }
                        (logForm basePortion IndependentPortion LogAdHocOnly coreNutrients)

                ratio : Float
                ratio =
                    toFloat quantity * toFloat pieceGrams / 250
            in
            case base of
                Err message ->
                    Expect.fail message

                Ok baseForm ->
                    baseForm
                        |> Editor.changeLogUnit draft "piece"
                        |> (\form ->
                                { totals = nutrientAmounts form
                                , weight =
                                    Editor.logPortionWeight form |> Maybe.andThen String.toFloat
                                , fields =
                                    Editor.foodLogFields form |> Maybe.map .unit
                                }
                           )
                        |> Ok
                        |> expectApplied
                            { totals =
                                nutrientAmounts baseForm |> List.map ((*) ratio)
                            , weight = Just (toFloat quantity * toFloat pieceGrams)
                            , fields = Just "piece"
                            }



-- HELPERS


type alias Portion =
    { date : String, quantity : String, unit : String }


type alias Applied a =
    { totals : List Float
    , weight : Maybe Float
    , fields : Maybe a
    }


expectApplied :
    { totals : List Float, weight : Maybe Float, fields : Maybe a }
    -> Result String (Applied a)
    -> Expect.Expectation
expectApplied expected actual =
    case actual of
        Err message ->
            Expect.fail message

        Ok value ->
            Expect.all
                [ \_ -> expectCloseList expected.totals value.totals
                , \_ -> expectCloseMaybe expected.weight value.weight
                , \_ -> Expect.equal expected.fields value.fields
                ]
                ()


expectCloseList : List Float -> List Float -> Expect.Expectation
expectCloseList expected actual =
    if List.length expected /= List.length actual then
        Expect.fail
            ("expected "
                ++ String.fromInt (List.length expected)
                ++ " amounts, got "
                ++ String.fromInt (List.length actual)
            )

    else
        Expect.all
            (List.map2
                (\expectedValue actualValue () ->
                    expectClose expectedValue actualValue
                )
                expected
                actual
            )
            ()


expectCloseMaybe : Maybe Float -> Maybe Float -> Expect.Expectation
expectCloseMaybe expected actual =
    case ( expected, actual ) of
        ( Just expectedValue, Just actualValue ) ->
            expectClose expectedValue actualValue

        _ ->
            Expect.equal expected actual


expectClose : Float -> Float -> Expect.Expectation
expectClose expected actual =
    Expect.within (Expect.Absolute 0.000001) expected actual


nutrientAmounts : FormModel -> List Float
nutrientAmounts form =
    List.filterMap (.amount >> String.toFloat) form.nutrients


setAmount : String -> String -> List NutrientRow -> List NutrientRow
setAmount code value rows =
    List.map
        (\row ->
            if row.code == code then
                { row | amount = value }

            else
                row
        )
        rows


logForm : Portion -> PortionNutrition -> LogPersistence -> List NutrientRow -> FormModel
logForm portion nutrition persistence nutrients =
    let
        base : FormModel
        base =
            Editor.emptyLogForm (LocalDate.fromString portion.date) Nothing
    in
    { base
        | name = "Paneer wrap"
        , nutrients = nutrients
        , ctx =
            Editor.FoodLogCtx
                { date = portion.date
                , mealSlot = Nothing
                , quantity = portion.quantity
                , unit = portion.unit
                , notes = ""
                , nutrition = nutrition
                }
                persistence
    }


basePortion : Portion
basePortion =
    { date = "2026-09-14", quantity = "1", unit = "serving" }


coreNutrients : List NutrientRow
coreNutrients =
    [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
    , { code = "PROTEIN_G", amount = "24", unit = "g" }
    , { code = "CARBS_G", amount = "48", unit = "g" }
    , { code = "FAT_G", amount = "25", unit = "g" }
    ]


energyNutrients : Int -> List NutrientRow
energyNutrients amount =
    [ { code = "ENERGY_KCAL", amount = String.fromInt amount, unit = "kcal" }
    , { code = "PROTEIN_G", amount = "0", unit = "g" }
    , { code = "CARBS_G", amount = "0", unit = "g" }
    , { code = "FAT_G", amount = "0", unit = "g" }
    ]


coreCodes : List String
coreCodes =
    [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]


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


aiDraft : String -> FoodDraft
aiDraft amountPer100g =
    { name = "Paneer wrap"
    , brand = Nothing
    , categories = [ "wrap" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "serving"
    , nutrients =
        List.map (\code -> { code = code, amountPer100g = amountPer100g }) coreCodes
    , servings =
        [ { unit = "serving", gramsPerUnit = "250" }
        , { unit = "piece", gramsPerUnit = "125" }
        ]
    }


aiDraftWithPiece : Int -> FoodDraft
aiDraftWithPiece pieceGrams =
    let
        draft : FoodDraft
        draft =
            aiDraft "200"
    in
    { draft
        | servings =
            [ { unit = "serving", gramsPerUnit = "250" }
            , { unit = "piece", gramsPerUnit = String.fromInt pieceGrams }
            ]
    }
