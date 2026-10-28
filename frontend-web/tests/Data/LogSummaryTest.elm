module Data.LogSummaryTest exposing (tests)

import Data.LogSummary as LogSummary
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "Data.LogSummary"
        [ fuzz SupportFuzz.localDate "fromLogs [] is Nothing" <|
            \date ->
                LogSummary.fromLogs date []
                    |> Expect.equal Nothing
        , fuzz2
            SupportFuzz.localDate
            nonEmptyLogsFuzzer
            "non-empty logs always produce a dated summary"
          <|
            \date logs ->
                LogSummary.fromLogs date logs
                    |> Maybe.map .date
                    |> Expect.equal (Just date)
        , fuzz2 SupportFuzz.localDate nonEmptyLogsFuzzer "each field sums its own nutrient code" <|
            \date logs ->
                case LogSummary.fromLogs date logs of
                    Nothing ->
                        Expect.fail "non-empty logs must produce a summary"

                    Just summary ->
                        expectSummaryFields
                            (sumCode "ENERGY_KCAL" logs)
                            (sumCode "PROTEIN_G" logs)
                            (sumCode "CARBS_G" logs)
                            (sumCode "FAT_G" logs)
                            summary
        , fuzz3
            SupportFuzz.localDate
            nonEmptyLogsFuzzer
            nonEmptyLogsFuzzer
            "energy, protein, carbs, and fat are additive"
          <|
            \date left right ->
                case ( LogSummary.fromLogs date left, LogSummary.fromLogs date right ) of
                    ( Just leftSummary, Just rightSummary ) ->
                        case LogSummary.fromLogs date (left ++ right) of
                            Nothing ->
                                Expect.fail "combined non-empty logs must produce a summary"

                            Just combined ->
                                expectSummaryFields
                                    (leftSummary.energyKcal + rightSummary.energyKcal)
                                    (leftSummary.proteinG + rightSummary.proteinG)
                                    (leftSummary.carbsG + rightSummary.carbsG)
                                    (leftSummary.fatG + rightSummary.fatG)
                                    combined

                    _ ->
                        Expect.fail "non-empty logs must produce summaries"
        , fuzz2 SupportFuzz.localDate nonEmptyLogsFuzzer "fromLogs is order-independent" <|
            \date logs ->
                let
                    forward : Maybe LogSummary.DaySummary
                    forward =
                        LogSummary.fromLogs date logs

                    reversed : Maybe LogSummary.DaySummary
                    reversed =
                        LogSummary.fromLogs date (List.reverse logs)
                in
                case ( forward, reversed ) of
                    ( Just forwardSummary, Just backwardSummary ) ->
                        expectSummaryClose forwardSummary backwardSummary

                    _ ->
                        Expect.fail "non-empty logs must produce summaries"
        , fuzz2
            SupportFuzz.localDate
            zeroLogsFuzzer
            "zero and invalid nutrients still sum to zero"
          <|
            \date logs ->
                LogSummary.fromLogs date logs
                    |> Expect.equal
                        (Just
                            { date = date
                            , energyKcal = 0
                            , proteinG = 0
                            , carbsG = 0
                            , fatG = 0
                            }
                        )
        ]



-- Fuzzers


macroNutrientFuzzer : Fuzzer NutrientAmount
macroNutrientFuzzer =
    Fuzz.map3
        (\code amount unit -> { code = code, amount = amount, unit = unit })
        (Fuzz.oneOfValues
            [ "ENERGY_KCAL"
            , "PROTEIN_G"
            , "CARBS_G"
            , "FAT_G"
            , "FIBER_G"
            ]
        )
        SupportFuzz.nonNegativeAmountString
        (Fuzz.oneOfValues [ "g", "kcal" ])


summaryLogFuzzer : Fuzzer { nutrients : List NutrientAmount }
summaryLogFuzzer =
    Fuzz.map
        (\nutrients -> { nutrients = nutrients })
        (Fuzz.list macroNutrientFuzzer)


nonEmptyLogsFuzzer : Fuzzer (List { nutrients : List NutrientAmount })
nonEmptyLogsFuzzer =
    Fuzz.map2 (::) summaryLogFuzzer (Fuzz.list summaryLogFuzzer)


zeroLogFuzzer : Fuzzer { nutrients : List NutrientAmount }
zeroLogFuzzer =
    Fuzz.map
        (\nutrients -> { nutrients = nutrients })
        (Fuzz.list
            (Fuzz.map3
                (\code amount unit -> { code = code, amount = amount, unit = unit })
                (Fuzz.oneOfValues
                    [ "ENERGY_KCAL"
                    , "PROTEIN_G"
                    , "CARBS_G"
                    , "FAT_G"
                    , "FIBER_G"
                    ]
                )
                zeroAmountFuzzer
                (Fuzz.oneOfValues [ "g", "kcal" ])
            )
        )


zeroAmountFuzzer : Fuzzer String
zeroAmountFuzzer =
    Fuzz.oneOfValues [ "0", "0.0", "-1", "-0.5", "nope", "", " " ]


zeroLogsFuzzer : Fuzzer (List { nutrients : List NutrientAmount })
zeroLogsFuzzer =
    Fuzz.map2 (::) zeroLogFuzzer (Fuzz.list zeroLogFuzzer)



-- Assertions and references


summaryTolerance : Expect.FloatingPointTolerance
summaryTolerance =
    Expect.Relative 1.0e-9


sumCode : String -> List { nutrients : List NutrientAmount } -> Float
sumCode code logs =
    logs
        |> List.map (\log -> firstAmount code log.nutrients)
        |> List.sum


firstAmount : String -> List NutrientAmount -> Float
firstAmount code nutrients =
    nutrients
        |> List.filter (.code >> (==) code)
        |> List.head
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


expectSummaryFields :
    Float
    -> Float
    -> Float
    -> Float
    -> LogSummary.DaySummary
    -> Expect.Expectation
expectSummaryFields energy protein carbs fat summary =
    Expect.all
        [ \_ -> summary.energyKcal |> Expect.within summaryTolerance energy
        , \_ -> summary.proteinG |> Expect.within summaryTolerance protein
        , \_ -> summary.carbsG |> Expect.within summaryTolerance carbs
        , \_ -> summary.fatG |> Expect.within summaryTolerance fat
        ]
        ()


expectSummaryClose : LogSummary.DaySummary -> LogSummary.DaySummary -> Expect.Expectation
expectSummaryClose expected actual =
    expectSummaryFields expected.energyKcal expected.proteinG expected.carbsG expected.fatG actual
