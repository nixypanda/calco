module Data.NutritionDetailsTest exposing (tests)

import Data.NutritionDetails as Details exposing (GuidanceKind(..), NutrientStatus(..))
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "Data.NutritionDetails"
        [ describe "progressPercent"
            [ fuzz2 maybeFloatFuzzer maybeFloatFuzzer "informational nutrients have no progress" <|
                \known reference ->
                    Details.progressPercent (nutrient Informational known reference Available)
                        |> Expect.equal Nothing
            , fuzz3
                nonInformationalGuidanceFuzzer
                maybeFloatFuzzer
                maybeFloatFuzzer
                "is defined exactly when the reference is positive"
              <|
                \guidance known reference ->
                    let
                        result : Maybe Float
                        result =
                            Details.progressPercent
                                (nutrient guidance known reference Available)
                    in
                    case ( known, reference ) of
                        ( Just knownAmount, Just referenceAmount ) ->
                            if referenceAmount > 0 then
                                case result of
                                    Just percent ->
                                        percent
                                            |> Expect.within progressTolerance
                                                ((knownAmount / referenceAmount) * 100)

                                    Nothing ->
                                        Expect.fail "positive references must produce progress"

                            else
                                result |> Expect.equal Nothing

                        _ ->
                            result |> Expect.equal Nothing
            ]
        , describe "isDangerous"
            [ fuzz2
                guidanceKindFuzzer
                nutrientStatusFuzzer
                "is true exactly for Maximum and OverLimit"
              <|
                \guidance status ->
                    Details.isDangerous (nutrient guidance Nothing Nothing status)
                        |> Expect.equal
                            (guidance == Details.Maximum && status == Details.OverLimit)
            , fuzz2
                nonMaximumGuidanceFuzzer
                nutrientStatusFuzzer
                "informational and adequacy nutrients are never dangerous"
              <|
                \guidance status ->
                    Details.isDangerous (nutrient guidance Nothing Nothing status)
                        |> Expect.equal False
            , fuzz
                nonOverLimitStatusFuzzer
                "maximum nutrients below their limit are not dangerous"
              <|
                \status ->
                    Details.isDangerous (nutrient Details.Maximum Nothing Nothing status)
                        |> Expect.equal False
            ]
        ]



-- Fuzzers


maybeFloatFuzzer : Fuzzer (Maybe Float)
maybeFloatFuzzer =
    Fuzz.maybe (Fuzz.floatRange -1000 1000)


guidanceKindFuzzer : Fuzzer GuidanceKind
guidanceKindFuzzer =
    Fuzz.oneOfValues [ Details.Informational, Details.Adequacy, Details.Maximum ]


nonInformationalGuidanceFuzzer : Fuzzer GuidanceKind
nonInformationalGuidanceFuzzer =
    Fuzz.oneOfValues [ Details.Adequacy, Details.Maximum ]


nonMaximumGuidanceFuzzer : Fuzzer GuidanceKind
nonMaximumGuidanceFuzzer =
    Fuzz.oneOfValues [ Details.Informational, Details.Adequacy ]


nutrientStatusFuzzer : Fuzzer NutrientStatus
nutrientStatusFuzzer =
    Fuzz.oneOfValues
        [ Details.NoData
        , Details.PartialData
        , Details.Available
        , Details.BelowReference
        , Details.MetReference
        , Details.WithinLimit
        , Details.OverLimit
        ]


nonOverLimitStatusFuzzer : Fuzzer NutrientStatus
nonOverLimitStatusFuzzer =
    Fuzz.oneOfValues
        [ Details.NoData
        , Details.PartialData
        , Details.Available
        , Details.BelowReference
        , Details.MetReference
        , Details.WithinLimit
        ]



-- References


progressTolerance : Expect.FloatingPointTolerance
progressTolerance =
    Expect.Relative 1.0e-9


nutrient :
    GuidanceKind
    -> Maybe Float
    -> Maybe Float
    -> NutrientStatus
    -> Details.Nutrient
nutrient guidance known reference status =
    { code = "FIBER_G"
    , name = "Fiber"
    , section = Details.Carbohydrates
    , knownAmount = known
    , unit = "g"
    , referenceAmount = reference
    , guidanceKind = guidance
    , itemsWithData = 4
    , coverage = Details.CompleteCoverage
    , status = status
    }
