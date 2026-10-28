module Data.NutritionTest exposing (tests)

import Data.Nutrition as Nutrition exposing (Macro(..), NutrientAmount)
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3, test)


tests : Test
tests =
    describe "Data.Nutrition"
        [ describe "safeAmount"
            [ fuzz
                SupportFuzz.amountString
                "safeAmount is non-negative for every finite amount string"
              <|
                \raw ->
                    Nutrition.safeAmount raw
                        |> Expect.atLeast 0
            , fuzz SupportFuzz.amountString "safeAmount clamps the parsed amount at zero" <|
                \raw ->
                    let
                        actual : Float
                        actual =
                            Nutrition.safeAmount raw
                    in
                    case String.toFloat raw of
                        Nothing ->
                            actual |> Expect.equal 0

                        Just value ->
                            actual |> Expect.within amountTolerance (max 0 value)
            , fuzz (Fuzz.floatRange 0 100000) "safeAmount roundtrips finite non-negative floats" <|
                \value ->
                    Nutrition.safeAmount (String.fromFloat value)
                        |> Expect.within amountTolerance value
            ]
        , describe "scalePer100g"
            [ fuzz3
                (Fuzz.floatRange 0 500)
                (Fuzz.floatRange 0 500)
                (Fuzz.list per100gFuzzer)
                "scalePer100g is linear in grams"
              <|
                \first second nutrients ->
                    let
                        stepwise : List NutrientAmount
                        stepwise =
                            Nutrition.scalePer100g second
                                (toPer100g (Nutrition.scalePer100g first nutrients))
                    in
                    expectAmountLists
                        (Nutrition.scalePer100g (first * second / 100) nutrients)
                        stepwise
            , fuzz (Fuzz.list per100gFuzzer) "scaling by 100 preserves numeric amounts" <|
                \nutrients ->
                    expectAmountLists
                        (List.map
                            (\nutrient ->
                                { code = nutrient.code
                                , amount = nutrient.amountPer100g
                                , unit = nutrient.unit
                                }
                            )
                            nutrients
                        )
                        (Nutrition.scalePer100g 100 nutrients)
            , fuzz (Fuzz.list per100gFuzzer) "zero grams zeroes every amount" <|
                \nutrients ->
                    let
                        scaled : List NutrientAmount
                        scaled =
                            Nutrition.scalePer100g 0 nutrients
                    in
                    Expect.all
                        [ \_ -> List.map .code scaled |> Expect.equal (List.map .code nutrients)
                        , \_ -> List.map .unit scaled |> Expect.equal (List.map .unit nutrients)
                        , \_ ->
                            List.all
                                (\nutrient ->
                                    closeTo 0 (Nutrition.safeAmount nutrient.amount)
                                )
                                scaled
                                |> Expect.equal True
                        ]
                        ()
            , fuzz3
                quantityFuzzer
                (Fuzz.list servingFuzzer)
                (Fuzz.list per100gFuzzer)
                "nutrientsForQuantity is servingGrams composed with scalePer100g"
              <|
                \quantity servings nutrients ->
                    let
                        expected : Maybe (List NutrientAmount)
                        expected =
                            Nutrition.servingGrams quantity servings
                                |> Maybe.map
                                    (\grams -> Nutrition.scalePer100g grams nutrients)
                    in
                    Nutrition.nutrientsForQuantity quantity servings nutrients
                        |> expectMaybeAmountLists expected
            ]
        , describe "servingGrams"
            [ fuzz2
                (Fuzz.list servingFuzzer)
                positiveAmountString
                "grams pass through without a serving table"
              <|
                \servings amount ->
                    Nutrition.servingGrams { amount = amount, unit = "g" } servings
                        |> expectJustFloat (Nutrition.safeAmount amount)
            , fuzz3
                positiveAmountString
                positiveAmountString
                nonGramUnitFuzzer
                "a matching serving multiplies amount by grams per unit"
              <|
                \amount grams unit ->
                    Nutrition.servingGrams
                        { amount = amount, unit = unit }
                        [ { unit = unit, gramsPerUnit = grams } ]
                        |> expectJustFloat
                            (Nutrition.safeAmount amount * Nutrition.safeAmount grams)
            , fuzz2
                positiveAmountString
                (Fuzz.list servingFuzzer)
                "an unknown unit yields Nothing"
              <|
                \amount servings ->
                    Nutrition.servingGrams
                        { amount = amount, unit = "unknown-unit" }
                        (List.filter (\serving -> serving.unit /= "unknown-unit") servings)
                        |> Expect.equal Nothing
            , fuzz (Fuzz.list servingFuzzer) "a non-positive amount yields Nothing" <|
                \servings ->
                    Expect.all
                        (List.map
                            (\raw _ ->
                                Nutrition.servingGrams { amount = raw, unit = "g" } servings
                                    |> Expect.equal Nothing
                            )
                            [ "0", "-1", "" ]
                        )
                        ()
            , fuzz2
                positiveAmountString
                nonGramUnitFuzzer
                "a non-positive or missing gramsPerUnit yields Nothing"
              <|
                \amount unit ->
                    Expect.all
                        (List.map
                            (\grams _ ->
                                Nutrition.servingGrams
                                    { amount = amount, unit = unit }
                                    [ { unit = unit, gramsPerUnit = grams } ]
                                    |> Expect.equal Nothing
                            )
                            [ "0", "-1", "", "nope" ]
                        )
                        ()
            , fuzz positiveAmountString "the first matching serving wins when units repeat" <|
                \amount ->
                    Nutrition.servingGrams
                        { amount = amount, unit = "cup" }
                        [ { unit = "cup", gramsPerUnit = "100" }
                        , { unit = "cup", gramsPerUnit = "200" }
                        ]
                        |> expectJustFloat (Nutrition.safeAmount amount * 100)
            ]
        , describe "scaledSnapshotForQuantity"
            [ test "non-positive or missing saved and current amounts yield Nothing" <|
                \_ ->
                    let
                        nutrients : List NutrientAmount
                        nutrients =
                            [ { code = "PROTEIN_G", amount = "10", unit = "g" } ]

                        scaled : String -> String -> Maybe (List NutrientAmount)
                        scaled savedAmount currentAmount =
                            Nutrition.scaledSnapshotForQuantity
                                { amount = savedAmount, unit = "g" }
                                { amount = currentAmount, unit = "g" }
                                nutrients
                    in
                    Expect.all
                        (List.concatMap
                            (\bad ->
                                [ \_ -> scaled bad "1" |> Expect.equal Nothing
                                , \_ -> scaled "1" bad |> Expect.equal Nothing
                                ]
                            )
                            [ "0", "-1", "" ]
                        )
                        ()
            , fuzz3
                positiveAmountString
                unitFuzzer
                (Fuzz.list nutrientFuzzer)
                "the same quantity is an identity"
              <|
                \amount unit nutrients ->
                    let
                        quantity : { amount : String, unit : String }
                        quantity =
                            { amount = amount, unit = unit }
                    in
                    Nutrition.scaledSnapshotForQuantity quantity quantity nutrients
                        |> expectMaybeAmountLists (Just nutrients)
            , fuzz3
                positiveAmountString
                unitFuzzer
                (Fuzz.list nutrientFuzzer)
                "doubling the current amount doubles each amount"
              <|
                \amount unit nutrients ->
                    let
                        saved : { amount : String, unit : String }
                        saved =
                            { amount = amount, unit = unit }

                        current : { amount : String, unit : String }
                        current =
                            { amount = String.fromFloat (parsedAmount amount * 2), unit = unit }

                        expected : List NutrientAmount
                        expected =
                            List.map
                                (\nutrient ->
                                    { nutrient
                                        | amount =
                                            String.fromFloat (parsedAmount nutrient.amount * 2)
                                    }
                                )
                                nutrients
                    in
                    Nutrition.scaledSnapshotForQuantity saved current nutrients
                        |> expectMaybeAmountLists (Just expected)
            , fuzz3
                positiveAmountString
                unitFuzzer
                (Fuzz.list nutrientFuzzer)
                "a unit mismatch yields Nothing"
              <|
                \amount unit nutrients ->
                    let
                        saved : { amount : String, unit : String }
                        saved =
                            { amount = amount, unit = unit }

                        current : { amount : String, unit : String }
                        current =
                            { amount = amount, unit = otherUnit unit }
                    in
                    Nutrition.scaledSnapshotForQuantity saved current nutrients
                        |> Expect.equal Nothing
            , fuzz3
                positiveAmountString
                unitFuzzer
                (Fuzz.list nutrientFuzzer)
                "a non-positive current amount yields Nothing"
              <|
                \amount unit nutrients ->
                    let
                        saved : { amount : String, unit : String }
                        saved =
                            { amount = amount, unit = unit }

                        current : { amount : String, unit : String }
                        current =
                            { amount = "0", unit = unit }
                    in
                    Nutrition.scaledSnapshotForQuantity saved current nutrients
                        |> Expect.equal Nothing
            , fuzz3
                positiveAmountString
                unitFuzzer
                (Fuzz.list nutrientFuzzer)
                "a missing or non-positive saved amount yields Nothing"
              <|
                \amount unit nutrients ->
                    let
                        saved : { amount : String, unit : String }
                        saved =
                            { amount = "nope", unit = unit }

                        current : { amount : String, unit : String }
                        current =
                            { amount = amount, unit = unit }
                    in
                    Nutrition.scaledSnapshotForQuantity saved current nutrients
                        |> Expect.equal Nothing
            ]
        , describe "macroTotals"
            [ fuzz positiveAmountString "a single macro code maps only to its own field" <|
                \amount ->
                    let
                        grams : Float
                        grams =
                            Nutrition.safeAmount amount

                        totalsFor : String -> Nutrition.MacroTotals
                        totalsFor code =
                            Nutrition.macroTotals
                                [ { nutrients = [ { code = code, amount = amount, unit = "g" } ] } ]
                    in
                    Expect.all
                        [ \_ ->
                            totalsFor "PROTEIN_G"
                                |> expectMacroTotals
                                    { protein = grams
                                    , carbs = 0
                                    , fat = 0
                                    , proteinPct = 100
                                    , carbsPct = 0
                                    , fatPct = 0
                                    }
                        , \_ ->
                            totalsFor "CARBS_G"
                                |> expectMacroTotals
                                    { protein = 0
                                    , carbs = grams
                                    , fat = 0
                                    , proteinPct = 0
                                    , carbsPct = 100
                                    , fatPct = 0
                                    }
                        , \_ ->
                            totalsFor "FAT_G"
                                |> expectMacroTotals
                                    { protein = 0
                                    , carbs = 0
                                    , fat = grams
                                    , proteinPct = 0
                                    , carbsPct = 0
                                    , fatPct = 100
                                    }
                        ]
                        ()
            , fuzz2
                positiveAmountString
                positiveAmountString
                "fat and protein percentages use the 4/9 calorie factors"
              <|
                \proteinRaw fatRaw ->
                    let
                        protein : Float
                        protein =
                            Nutrition.safeAmount proteinRaw

                        fat : Float
                        fat =
                            Nutrition.safeAmount fatRaw

                        totals : Nutrition.MacroTotals
                        totals =
                            Nutrition.macroTotals
                                [ { nutrients =
                                        [ { code = "PROTEIN_G", amount = proteinRaw, unit = "g" }
                                        , { code = "FAT_G", amount = fatRaw, unit = "g" }
                                        ]
                                  }
                                ]
                    in
                    totals.fatPct
                        / totals.proteinPct
                        |> Expect.within (Expect.Relative 1.0e-9) ((9 * fat) / (4 * protein))
            , fuzz2
                positiveAmountString
                positiveAmountString
                "carb and protein percentages use the same 4 kcal factor"
              <|
                \proteinRaw carbsRaw ->
                    let
                        protein : Float
                        protein =
                            Nutrition.safeAmount proteinRaw

                        carbs : Float
                        carbs =
                            Nutrition.safeAmount carbsRaw

                        totals : Nutrition.MacroTotals
                        totals =
                            Nutrition.macroTotals
                                [ { nutrients =
                                        [ { code = "PROTEIN_G", amount = proteinRaw, unit = "g" }
                                        , { code = "CARBS_G", amount = carbsRaw, unit = "g" }
                                        ]
                                  }
                                ]
                    in
                    totals.carbsPct
                        / totals.proteinPct
                        |> Expect.within (Expect.Relative 1.0e-9) (carbs / protein)
            , fuzz2
                macroLogFuzzer
                macroLogFuzzer
                "protein, carbs, and fat are additive across logs"
              <|
                \left right ->
                    let
                        leftTotals : Nutrition.MacroTotals
                        leftTotals =
                            Nutrition.macroTotals [ left ]

                        rightTotals : Nutrition.MacroTotals
                        rightTotals =
                            Nutrition.macroTotals [ right ]

                        combined : Nutrition.MacroTotals
                        combined =
                            Nutrition.macroTotals [ left, right ]
                    in
                    expectMacroFields
                        (leftTotals.protein + rightTotals.protein)
                        (leftTotals.carbs + rightTotals.carbs)
                        (leftTotals.fat + rightTotals.fat)
                        combined
            , fuzz (Fuzz.list macroLogFuzzer) "permuting logs does not change the totals" <|
                \logs ->
                    Nutrition.macroTotals (List.reverse logs)
                        |> expectMacroTotalsClose (Nutrition.macroTotals logs)
            , fuzz (Fuzz.list macroLogFuzzer) "percentages sum to 100 when energy is positive" <|
                \logs ->
                    let
                        totals : Nutrition.MacroTotals
                        totals =
                            Nutrition.macroTotals logs

                        totalKcal : Float
                        totalKcal =
                            totals.protein * 4 + totals.carbs * 4 + totals.fat * 9

                        percentageSum : Float
                        percentageSum =
                            totals.proteinPct + totals.carbsPct + totals.fatPct
                    in
                    if totalKcal > 0 then
                        percentageSum |> Expect.within (Expect.Absolute 1.0e-6) 100

                    else
                        Expect.all
                            [ \_ -> totals.proteinPct |> Expect.equal 0
                            , \_ -> totals.carbsPct |> Expect.equal 0
                            , \_ -> totals.fatPct |> Expect.equal 0
                            ]
                            ()
            , fuzz (Fuzz.list macroLogFuzzer) "non-negative inputs produce non-negative totals" <|
                \logs ->
                    let
                        totals : Nutrition.MacroTotals
                        totals =
                            Nutrition.macroTotals logs
                    in
                    Expect.all
                        [ \_ -> totals.protein |> Expect.atLeast 0
                        , \_ -> totals.carbs |> Expect.atLeast 0
                        , \_ -> totals.fat |> Expect.atLeast 0
                        , \_ -> totals.proteinPct |> Expect.atLeast 0
                        , \_ -> totals.carbsPct |> Expect.atLeast 0
                        , \_ -> totals.fatPct |> Expect.atLeast 0
                        ]
                        ()
            ]
        , describe "dominantMacro"
            [ fuzz (Fuzz.list zeroMacroFuzzer) "all-zero or absent macros have no dominant macro" <|
                \nutrients ->
                    Nutrition.dominantMacro nutrients
                        |> Expect.equal Nothing
            , fuzz3
                (Fuzz.floatRange 0 1000)
                (Fuzz.floatRange 0 1000)
                (Fuzz.floatRange 0 1000)
                "the dominant macro has the highest calorie share at 4/4/9"
              <|
                \protein carbs fat ->
                    expectDominantConsistent protein carbs fat
            , fuzz (Fuzz.intRange 1 1000) "calorie ties break Protein then Carbs then Fat" <|
                \n ->
                    let
                        scale : Float
                        scale =
                            toFloat n
                    in
                    Expect.all
                        [ \_ ->
                            Nutrition.dominantMacro
                                [ macro "PROTEIN_G" (9 * scale)
                                , macro "CARBS_G" (9 * scale)
                                , macro "FAT_G" (4 * scale)
                                ]
                                |> Expect.equal (Just Protein)
                        , \_ ->
                            Nutrition.dominantMacro
                                [ macro "PROTEIN_G" 0
                                , macro "CARBS_G" (9 * scale)
                                , macro "FAT_G" (4 * scale)
                                ]
                                |> Expect.equal (Just Carbs)
                        , \_ ->
                            Nutrition.dominantMacro
                                [ macro "PROTEIN_G" (9 * scale)
                                , macro "CARBS_G" 0
                                , macro "FAT_G" (4 * scale)
                                ]
                                |> Expect.equal (Just Protein)
                        , \_ ->
                            Nutrition.dominantMacro
                                [ macro "PROTEIN_G" 0
                                , macro "CARBS_G" 0
                                , macro "FAT_G" scale
                                ]
                                |> Expect.equal (Just Fat)
                        ]
                        ()
            ]
        , describe "totalsFromLogs"
            [ test "an empty log list has no totals" <|
                \_ ->
                    Nutrition.totalsFromLogs []
                        |> Expect.equal []
            , fuzz (Fuzz.list totalsLogFuzzer) "codes keep first-seen order" <|
                \logs ->
                    let
                        flattened : List NutrientAmount
                        flattened =
                            List.concatMap .nutrients logs
                    in
                    Nutrition.totalsFromLogs logs
                        |> List.map .code
                        |> Expect.equal (firstSeen (List.map .code flattened))
            , fuzz (Fuzz.list totalsLogFuzzer) "each code appears exactly once" <|
                \logs ->
                    let
                        flattened : List NutrientAmount
                        flattened =
                            List.concatMap .nutrients logs
                    in
                    Nutrition.totalsFromLogs logs
                        |> List.map .code
                        |> List.length
                        |> Expect.equal (List.length (firstSeen (List.map .code flattened)))
            , fuzz (Fuzz.list totalsLogFuzzer) "each total is the sum of that code's amounts" <|
                \logs ->
                    let
                        flattened : List NutrientAmount
                        flattened =
                            List.concatMap .nutrients logs
                    in
                    Nutrition.totalsFromLogs logs
                        |> List.all
                            (\total ->
                                closeTo
                                    (totalFor total.code flattened)
                                    (Nutrition.safeAmount total.amount)
                            )
                        |> Expect.equal True
            , fuzz (Fuzz.list totalsLogFuzzer) "a code's unit comes from its first occurrence" <|
                \logs ->
                    let
                        flattened : List NutrientAmount
                        flattened =
                            List.concatMap .nutrients logs
                    in
                    Nutrition.totalsFromLogs logs
                        |> List.all
                            (\total -> total.unit == unitFor total.code flattened)
                        |> Expect.equal True
            ]
        , describe "summaryToNutrients"
            [ fuzz summaryFuzzer "missing fields become zero and present values are preserved" <|
                \summary ->
                    Nutrition.summaryToNutrients summary
                        |> Expect.equal
                            [ { code = "PROTEIN_G"
                              , amount = Maybe.withDefault "0" summary.proteinG
                              , unit = "g"
                              }
                            , { code = "CARBS_G"
                              , amount = Maybe.withDefault "0" summary.carbsG
                              , unit = "g"
                              }
                            , { code = "FAT_G"
                              , amount = Maybe.withDefault "0" summary.fatG
                              , unit = "g"
                              }
                            ]
            ]
        ]



-- Fuzzers


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
    Fuzz.map3
        (\code amount unit -> { code = code, amountPer100g = amount, unit = unit })
        codeFuzzer
        SupportFuzz.nonNegativeAmountString
        unitFuzzer


nutrientFuzzer : Fuzzer NutrientAmount
nutrientFuzzer =
    Fuzz.map3
        (\code amount unit -> { code = code, amount = amount, unit = unit })
        codeFuzzer
        SupportFuzz.amountString
        unitFuzzer


quantityFuzzer : Fuzzer { amount : String, unit : String }
quantityFuzzer =
    Fuzz.map2
        (\amount unit -> { amount = amount, unit = unit })
        SupportFuzz.nonNegativeAmountString
        unitFuzzer


servingFuzzer : Fuzzer { unit : String, gramsPerUnit : String }
servingFuzzer =
    Fuzz.map2
        (\unit grams -> { unit = unit, gramsPerUnit = grams })
        unitFuzzer
        SupportFuzz.amountString


positiveAmountString : Fuzzer String
positiveAmountString =
    Fuzz.map (\value -> String.fromFloat (value + 0.01)) (Fuzz.floatRange 0 1000)


macroNutrientFuzzer : Fuzzer NutrientAmount
macroNutrientFuzzer =
    Fuzz.map3
        (\code amount unit -> { code = code, amount = amount, unit = unit })
        codeFuzzer
        SupportFuzz.nonNegativeAmountString
        unitFuzzer


macroLogFuzzer : Fuzzer MacroLog
macroLogFuzzer =
    Fuzz.map (\nutrients -> { nutrients = nutrients }) (Fuzz.list macroNutrientFuzzer)


zeroMacroFuzzer : Fuzzer NutrientAmount
zeroMacroFuzzer =
    Fuzz.map2
        (\code amount -> { code = code, amount = amount, unit = "g" })
        (Fuzz.oneOfValues [ "PROTEIN_G", "CARBS_G", "FAT_G", "FIBER_G" ])
        (Fuzz.oneOfValues [ "0", "0.0", "-1", "nope", "" ])


totalsLogFuzzer : Fuzzer MacroLog
totalsLogFuzzer =
    Fuzz.map
        (\nutrients -> { nutrients = nutrients })
        (Fuzz.list
            (Fuzz.map3
                (\code amount unit -> { code = code, amount = amount, unit = unit })
                codeFuzzer
                SupportFuzz.amountString
                unitFuzzer
            )
        )


summaryFuzzer : Fuzzer Nutrition.NutritionSummary
summaryFuzzer =
    Fuzz.map5
        (\energy protein carbs fat fiber ->
            { energyKcal = energy
            , proteinG = protein
            , carbsG = carbs
            , fatG = fat
            , fiberG = fiber
            }
        )
        (Fuzz.maybe SupportFuzz.amountString)
        (Fuzz.maybe SupportFuzz.amountString)
        (Fuzz.maybe SupportFuzz.amountString)
        (Fuzz.maybe SupportFuzz.amountString)
        (Fuzz.maybe SupportFuzz.amountString)



-- Assertions and references


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
                (\left right ->
                    closeTo (parsedAmount left.amount) (parsedAmount right.amount)
                )
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


expectMacroFields : Float -> Float -> Float -> Nutrition.MacroTotals -> Expect.Expectation
expectMacroFields protein carbs fat totals =
    Expect.all
        [ \_ -> totals.protein |> Expect.within amountTolerance protein
        , \_ -> totals.carbs |> Expect.within amountTolerance carbs
        , \_ -> totals.fat |> Expect.within amountTolerance fat
        ]
        ()


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


expectMacroTotalsClose : Nutrition.MacroTotals -> Nutrition.MacroTotals -> Expect.Expectation
expectMacroTotalsClose expected actual =
    Expect.all
        [ \_ -> actual.protein |> Expect.within amountTolerance expected.protein
        , \_ -> actual.carbs |> Expect.within amountTolerance expected.carbs
        , \_ -> actual.fat |> Expect.within amountTolerance expected.fat
        , \_ -> actual.proteinPct |> Expect.within amountTolerance expected.proteinPct
        , \_ -> actual.carbsPct |> Expect.within amountTolerance expected.carbsPct
        , \_ -> actual.fatPct |> Expect.within amountTolerance expected.fatPct
        ]
        ()


macro : String -> Float -> NutrientAmount
macro code amount =
    { code = code, amount = String.fromFloat amount, unit = "g" }


expectDominantConsistent : Float -> Float -> Float -> Expect.Expectation
expectDominantConsistent protein carbs fat =
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

        result : Maybe Macro
        result =
            Nutrition.dominantMacro
                [ macro "PROTEIN_G" protein
                , macro "CARBS_G" carbs
                , macro "FAT_G" fat
                ]
    in
    case result of
        Nothing ->
            proteinKcal
                + carbsKcal
                + fatKcal
                <= 0
                |> Expect.equal True

        Just Protein ->
            (proteinKcal >= carbsKcal && proteinKcal >= fatKcal)
                |> Expect.equal True

        Just Carbs ->
            (carbsKcal >= proteinKcal && carbsKcal >= fatKcal)
                |> Expect.equal True

        Just Fat ->
            (fatKcal > proteinKcal && fatKcal > carbsKcal)
                |> Expect.equal True


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
    flattened
        |> List.filter (.code >> (==) code)
        |> List.map (.amount >> parsedAmount)
        |> List.sum


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
