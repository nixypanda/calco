module Data.NutritionTest exposing (tests)

import Data.Nutrition as Nutrition exposing (Macro(..), NutrientAmount)
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz3)


tests : Test
tests =
    describe "Data.Nutrition"
        [ fuzz3 (Fuzz.floatRange 0 500)
            (Fuzz.floatRange 0 500)
            (Fuzz.list per100gFuzzer)
            "scalePer100g is linear, preserves shape, and zeroes at zero grams"
          <|
            \first second nutrients ->
                let
                    stepwise : List NutrientAmount
                    stepwise =
                        Nutrition.scalePer100g second
                            (toPer100g (Nutrition.scalePer100g first nutrients))

                    zeroed : List NutrientAmount
                    zeroed =
                        Nutrition.scalePer100g 0 nutrients
                in
                Expect.all
                    [ \_ ->
                        expectAmountLists (Nutrition.scalePer100g (first * second / 100) nutrients)
                            stepwise
                    , \_ ->
                        expectAmountLists (toNutrientAmounts nutrients)
                            (Nutrition.scalePer100g 100 nutrients)
                    , \_ ->
                        List.map .code zeroed |> Expect.equal (List.map .code nutrients)
                    , \_ ->
                        List.map .unit zeroed |> Expect.equal (List.map .unit nutrients)
                    , \_ ->
                        List.all (\nutrient -> closeTo 0 (Nutrition.safeAmount nutrient.amount))
                            zeroed
                            |> Expect.equal True
                    ]
                    ()
        , fuzz3 positiveAmountString
            positiveAmountString
            nonGramUnitFuzzer
            "servingGrams passes grams through, scales matching servings, and rejects bad input"
          <|
            \amount grams unit ->
                let
                    matching : List { unit : String, gramsPerUnit : String }
                    matching =
                        [ { unit = unit, gramsPerUnit = grams } ]

                    badAmounts : List String
                    badAmounts =
                        [ "0", "-1", "" ]

                    badGrams : List String
                    badGrams =
                        [ "0", "-1", "", "nope" ]
                in
                Expect.all
                    [ \_ ->
                        Nutrition.servingGrams { amount = amount, unit = "g" } matching
                            |> expectJustFloat (Nutrition.safeAmount amount)
                    , \_ ->
                        Nutrition.servingGrams { amount = amount, unit = unit } matching
                            |> expectJustFloat
                                (Nutrition.safeAmount amount * Nutrition.safeAmount grams)
                    , \_ ->
                        Nutrition.servingGrams { amount = amount, unit = "unknown-unit" } matching
                            |> Expect.equal Nothing
                    , \_ ->
                        List.map
                            (\bad ->
                                Nutrition.servingGrams { amount = bad, unit = "g" } matching
                            )
                            badAmounts
                            |> List.all ((==) Nothing)
                            |> Expect.equal True
                    , \_ ->
                        List.map
                            (\bad ->
                                Nutrition.servingGrams { amount = amount, unit = unit }
                                    [ { unit = unit, gramsPerUnit = bad } ]
                            )
                            badGrams
                            |> List.all ((==) Nothing)
                            |> Expect.equal True
                    , \_ ->
                        Nutrition.servingGrams { amount = amount, unit = "cup" }
                            [ { unit = "cup", gramsPerUnit = "100" }
                            , { unit = "cup", gramsPerUnit = "200" }
                            ]
                            |> expectJustFloat (Nutrition.safeAmount amount * 100)
                    ]
                    ()
        , fuzz3 positiveAmountString
            unitFuzzer
            (Fuzz.list nutrientFuzzer)
            "scaledSnapshotForQuantity handles identity, doubling, and missing input"
          <|
            \amount unit nutrients ->
                let
                    saved : { amount : String, unit : String }
                    saved =
                        { amount = amount, unit = unit }

                    doubled : { amount : String, unit : String }
                    doubled =
                        { amount = String.fromFloat (parsedAmount amount * 2), unit = unit }

                    doubledNutrients : List NutrientAmount
                    doubledNutrients =
                        List.map
                            (\nutrient ->
                                { nutrient
                                    | amount =
                                        String.fromFloat (parsedAmount nutrient.amount * 2)
                                }
                            )
                            nutrients

                    badAmounts : List String
                    badAmounts =
                        [ "0", "-1", "", "nope", "abc" ]
                in
                Expect.all
                    [ \_ ->
                        Nutrition.scaledSnapshotForQuantity saved saved nutrients
                            |> expectMaybeAmountLists (Just nutrients)
                    , \_ ->
                        Nutrition.scaledSnapshotForQuantity saved doubled nutrients
                            |> expectMaybeAmountLists (Just doubledNutrients)
                    , \_ ->
                        Nutrition.scaledSnapshotForQuantity saved
                            { amount = amount, unit = otherUnit unit }
                            nutrients
                            |> Expect.equal Nothing
                    , \_ ->
                        List.map
                            (\bad ->
                                Nutrition.scaledSnapshotForQuantity saved
                                    { amount = bad, unit = unit }
                                    nutrients
                            )
                            badAmounts
                            |> List.all ((==) Nothing)
                            |> Expect.equal True
                    , \_ ->
                        List.map
                            (\bad ->
                                Nutrition.scaledSnapshotForQuantity { amount = bad, unit = unit }
                                    saved
                                    nutrients
                            )
                            badAmounts
                            |> List.all ((==) Nothing)
                            |> Expect.equal True
                    ]
                    ()
        , fuzz (Fuzz.list macroLogFuzzer)
            "macroTotals sums each macro across logs and applies 4/4/9 percentages"
          <|
            \logs ->
                let
                    protein : Float
                    protein =
                        totalOf "PROTEIN_G" logs

                    carbs : Float
                    carbs =
                        totalOf "CARBS_G" logs

                    fat : Float
                    fat =
                        totalOf "FAT_G" logs

                    totalKcal : Float
                    totalKcal =
                        protein * 4 + carbs * 4 + fat * 9

                    percent : Float -> Float
                    percent kcal =
                        if totalKcal > 0 then
                            kcal / totalKcal * 100

                        else
                            0
                in
                Nutrition.macroTotals logs
                    |> expectMacroTotals
                        { protein = protein
                        , carbs = carbs
                        , fat = fat
                        , proteinPct = percent (protein * 4)
                        , carbsPct = percent (carbs * 4)
                        , fatPct = percent (fat * 9)
                        }
        , fuzz3 (Fuzz.floatRange 0 1000)
            (Fuzz.floatRange 0 1000)
            (Fuzz.floatRange 0 1000)
            "dominantMacro picks the highest calorie share and prefers Protein then Carbs on ties"
          <|
            \protein carbs fat ->
                Expect.all
                    [ \_ ->
                        Nutrition.dominantMacro
                            [ macroFromFloat "PROTEIN_G" protein
                            , macroFromFloat "CARBS_G" carbs
                            , macroFromFloat "FAT_G" fat
                            ]
                            |> Expect.equal (expectedDominant protein carbs fat)
                    , \_ -> Nutrition.dominantMacro [] |> Expect.equal Nothing
                    , \_ ->
                        Nutrition.dominantMacro
                            [ macro "PROTEIN_G" "nope"
                            , macro "CARBS_G" "-1"
                            , macro "FAT_G" ""
                            ]
                            |> Expect.equal Nothing
                    , \_ ->
                        Nutrition.dominantMacro
                            [ macro "PROTEIN_G" "9"
                            , macro "CARBS_G" "9"
                            , macro "FAT_G" "4"
                            ]
                            |> Expect.equal (Just Protein)
                    , \_ ->
                        Nutrition.dominantMacro
                            [ macro "PROTEIN_G" "0"
                            , macro "CARBS_G" "9"
                            , macro "FAT_G" "4"
                            ]
                            |> Expect.equal (Just Carbs)
                    , \_ ->
                        Nutrition.dominantMacro
                            [ macro "PROTEIN_G" "0"
                            , macro "CARBS_G" "0"
                            , macro "FAT_G" "1"
                            ]
                            |> Expect.equal (Just Fat)
                    ]
                    ()
        , fuzz (Fuzz.list totalsLogFuzzer)
            "totalsFromLogs emits one first-seen total per code with its first unit"
          <|
            \logs ->
                let
                    flattened : List NutrientAmount
                    flattened =
                        List.concatMap .nutrients logs

                    totals : List NutrientAmount
                    totals =
                        Nutrition.totalsFromLogs logs
                in
                Expect.all
                    [ \_ -> Nutrition.totalsFromLogs [] |> Expect.equal []
                    , \_ ->
                        List.map .code totals |> Expect.equal (firstSeen (List.map .code flattened))
                    , \_ ->
                        List.all
                            (\total ->
                                closeTo (totalFor total.code flattened)
                                    (Nutrition.safeAmount total.amount)
                            )
                            totals
                            |> Expect.equal True
                    , \_ ->
                        List.all (\total -> total.unit == unitFor total.code flattened) totals
                            |> Expect.equal True
                    ]
                    ()
        ]


type alias Per100g =
    { code : String, amountPer100g : String, unit : String }


type alias MacroLog =
    { nutrients : List NutrientAmount }


codeFuzzer : Fuzzer String
codeFuzzer =
    Fuzz.oneOfValues [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G" ]


unitFuzzer : Fuzzer String
unitFuzzer =
    Fuzz.oneOfValues [ "g", "mg", "kcal", "piece" ]


nonGramUnitFuzzer : Fuzzer String
nonGramUnitFuzzer =
    Fuzz.oneOfValues [ "mg", "kcal", "piece", "cup" ]


per100gFuzzer : Fuzzer Per100g
per100gFuzzer =
    Fuzz.map3 (\code amount unit -> { code = code, amountPer100g = amount, unit = unit })
        codeFuzzer
        SupportFuzz.nonNegativeAmountString
        unitFuzzer


nutrientFuzzer : Fuzzer NutrientAmount
nutrientFuzzer =
    Fuzz.map3 (\code amount unit -> { code = code, amount = amount, unit = unit })
        codeFuzzer
        SupportFuzz.amountString
        unitFuzzer


positiveAmountString : Fuzzer String
positiveAmountString =
    Fuzz.map (\value -> String.fromFloat (value + 0.01)) (Fuzz.floatRange 0 1000)


macroLogFuzzer : Fuzzer MacroLog
macroLogFuzzer =
    Fuzz.map3
        (\protein carbs fat ->
            { nutrients =
                [ macro "PROTEIN_G" protein
                , macro "CARBS_G" carbs
                , macro "FAT_G" fat
                ]
            }
        )
        SupportFuzz.nonNegativeAmountString
        SupportFuzz.nonNegativeAmountString
        SupportFuzz.nonNegativeAmountString


totalsLogFuzzer : Fuzzer MacroLog
totalsLogFuzzer =
    Fuzz.map (\nutrients -> { nutrients = nutrients })
        (Fuzz.list
            (Fuzz.map3
                (\code amount unit -> { code = code, amount = amount, unit = unit })
                codeFuzzer
                SupportFuzz.amountString
                unitFuzzer
            )
        )


amountTolerance : Expect.FloatingPointTolerance
amountTolerance =
    Expect.Relative 1.0e-9


parsedAmount : String -> Float
parsedAmount raw =
    case String.toFloat raw of
        Just value ->
            max 0 value

        Nothing ->
            0


toPer100g : List NutrientAmount -> List Per100g
toPer100g nutrients =
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amountPer100g = nutrient.amount
            , unit = nutrient.unit
            }
        )
        nutrients


toNutrientAmounts : List Per100g -> List NutrientAmount
toNutrientAmounts nutrients =
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amount = nutrient.amountPer100g
            , unit = nutrient.unit
            }
        )
        nutrients


closeTo : Float -> Float -> Bool
closeTo expected actual =
    abs (expected - actual) <= 1.0e-9 * max 1 (max (abs expected) (abs actual))


expectAmountLists : List NutrientAmount -> List NutrientAmount -> Expect.Expectation
expectAmountLists expected actual =
    Expect.all
        [ \_ -> List.map .code actual |> Expect.equal (List.map .code expected)
        , \_ -> List.map .unit actual |> Expect.equal (List.map .unit expected)
        , \_ ->
            List.map2
                (\left right -> closeTo (parsedAmount left.amount) (parsedAmount right.amount))
                expected
                actual
                |> List.all identity
                |> Expect.equal True
        ]
        ()


expectMaybeAmountLists :
    Maybe (List NutrientAmount)
    -> Maybe (List NutrientAmount)
    -> Expect.Expectation
expectMaybeAmountLists expected actual =
    case ( expected, actual ) of
        ( Nothing, Nothing ) ->
            Expect.pass

        ( Just expectedList, Just actualList ) ->
            expectAmountLists expectedList actualList

        _ ->
            Expect.fail "expected both kinds of available nutrients or both missing"


expectJustFloat : Float -> Maybe Float -> Expect.Expectation
expectJustFloat expected actual =
    case actual of
        Just value ->
            value |> Expect.within amountTolerance expected

        Nothing ->
            Expect.fail "expected a serving gram value"


expectMacroTotals :
    { protein : Float
    , carbs : Float
    , fat : Float
    , proteinPct : Float
    , carbsPct : Float
    , fatPct : Float
    }
    -> Nutrition.MacroTotals
    -> Expect.Expectation
expectMacroTotals expected totals =
    Expect.all
        [ \_ -> totals.protein |> Expect.within amountTolerance expected.protein
        , \_ -> totals.carbs |> Expect.within amountTolerance expected.carbs
        , \_ -> totals.fat |> Expect.within amountTolerance expected.fat
        , \_ -> totals.proteinPct |> Expect.within amountTolerance expected.proteinPct
        , \_ -> totals.carbsPct |> Expect.within amountTolerance expected.carbsPct
        , \_ -> totals.fatPct |> Expect.within amountTolerance expected.fatPct
        ]
        ()


macro : String -> String -> NutrientAmount
macro code amount =
    { code = code, amount = amount, unit = "g" }


macroFromFloat : String -> Float -> NutrientAmount
macroFromFloat code value =
    macro code (String.fromFloat value)


expectedDominant : Float -> Float -> Float -> Maybe Macro
expectedDominant protein carbs fat =
    let
        proteinKcal : Float
        proteinKcal =
            protein * 4

        carbsKcal : Float
        carbsKcal =
            carbs * 4

        fatKcal : Float
        fatKcal =
            fat * 9
    in
    if proteinKcal + carbsKcal + fatKcal <= 0 then
        Nothing

    else if proteinKcal >= carbsKcal && proteinKcal >= fatKcal then
        Just Protein

    else if carbsKcal >= proteinKcal && carbsKcal >= fatKcal then
        Just Carbs

    else
        Just Fat


totalOf : String -> List MacroLog -> Float
totalOf code logs =
    logs |> List.map (\log -> amountFor code log.nutrients) |> List.sum


amountFor : String -> List NutrientAmount -> Float
amountFor code nutrients =
    nutrients
        |> List.filter (.code >> (==) code)
        |> List.head
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


firstSeen : List String -> List String
firstSeen values =
    List.foldl
        (\value seen ->
            if List.member value seen then
                seen

            else
                seen ++ [ value ]
        )
        []
        values


totalFor : String -> List NutrientAmount -> Float
totalFor code flattened =
    flattened |> List.filter (.code >> (==) code) |> List.map (.amount >> parsedAmount) |> List.sum


unitFor : String -> List NutrientAmount -> String
unitFor code flattened =
    flattened
        |> List.filter (.code >> (==) code)
        |> List.head
        |> Maybe.map .unit
        |> Maybe.withDefault ""


otherUnit : String -> String
otherUnit unit =
    if unit == "g" then
        "cup"

    else
        "g"
