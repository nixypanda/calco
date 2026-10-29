module Data.NutritionDetailsTest exposing (tests)

import Data.NutritionDetails as Details exposing (GuidanceKind(..), NutrientStatus(..))
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz2, fuzz3)


tests : Test
tests =
    describe "Data.NutritionDetails"
        [ fuzz3 guidanceKindFuzzer
            maybeFloatFuzzer
            maybeFloatFuzzer
            "progressPercent is defined exactly for non-informational positive references"
          <|
            \guidance known reference ->
                let
                    expected : Maybe Float
                    expected =
                        case ( guidance, known, reference ) of
                            ( Informational, _, _ ) ->
                                Nothing

                            ( _, Just knownAmount, Just referenceAmount ) ->
                                if referenceAmount > 0 then
                                    Just ((knownAmount / referenceAmount) * 100)

                                else
                                    Nothing

                            _ ->
                                Nothing

                    actual : Maybe Float
                    actual =
                        Details.progressPercent (nutrient guidance known reference Available)
                in
                case ( actual, expected ) of
                    ( Just actualProgress, Just expectedProgress ) ->
                        actualProgress |> Expect.within progressTolerance expectedProgress

                    _ ->
                        actual |> Expect.equal expected
        , fuzz2 guidanceKindFuzzer
            nutrientStatusFuzzer
            "isDangerous is true exactly for Maximum and OverLimit"
          <|
            \guidance status ->
                Details.isDangerous (nutrient guidance Nothing Nothing status)
                    |> Expect.equal
                        (guidance == Details.Maximum && status == Details.OverLimit)
        ]


maybeFloatFuzzer : Fuzzer (Maybe Float)
maybeFloatFuzzer =
    Fuzz.maybe (Fuzz.floatRange -1000 1000)


guidanceKindFuzzer : Fuzzer GuidanceKind
guidanceKindFuzzer =
    Fuzz.oneOfValues [ Details.Informational, Details.Adequacy, Details.Maximum ]


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
