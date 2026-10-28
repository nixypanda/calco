module Data.LogSummaryTest exposing (tests)

import Data.LogSummary as LogSummary
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2)


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
            "fromLogs preserves the date and sums each field from its own code"
          <|
            \date logs ->
                case LogSummary.fromLogs date logs of
                    Nothing ->
                        Expect.fail "non-empty logs must produce a summary"

                    Just summary ->
                        Expect.all
                            [ \_ -> summary.date |> Expect.equal date
                            , \_ ->
                                summary.energyKcal
                                    |> Expect.within summaryTolerance (sumCode "ENERGY_KCAL" logs)
                            , \_ ->
                                summary.proteinG
                                    |> Expect.within summaryTolerance (sumCode "PROTEIN_G" logs)
                            , \_ ->
                                summary.carbsG
                                    |> Expect.within summaryTolerance (sumCode "CARBS_G" logs)
                            , \_ ->
                                summary.fatG
                                    |> Expect.within summaryTolerance (sumCode "FAT_G" logs)
                            ]
                            ()
        ]


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
        SupportFuzz.amountString
        (Fuzz.oneOfValues [ "g", "kcal" ])


summaryLogFuzzer : Fuzzer { nutrients : List NutrientAmount }
summaryLogFuzzer =
    Fuzz.map
        (\nutrients -> { nutrients = nutrients })
        (Fuzz.list macroNutrientFuzzer)


nonEmptyLogsFuzzer : Fuzzer (List { nutrients : List NutrientAmount })
nonEmptyLogsFuzzer =
    Fuzz.map2 (::) summaryLogFuzzer (Fuzz.list summaryLogFuzzer)


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
