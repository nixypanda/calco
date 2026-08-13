module NutritionDetailsTest exposing (tests)

import Data.NutritionDetails as Details
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.NutritionDetails"
        [ test "decoder accepts nullable references and string or numeric decimals" <|
            \_ ->
                Decode.decodeString Details.decoder responseJson
                    |> Result.map
                        (\report ->
                            report.nutrients
                                |> List.map
                                    (\item ->
                                        { code = item.code
                                        , section = item.section
                                        , knownAmount = item.knownAmount
                                        , referenceAmount = item.referenceAmount
                                        , guidanceKind = item.guidanceKind
                                        , status = item.status
                                        }
                                    )
                        )
                    |> Expect.equal
                        (Ok
                            [ { code = "FIBER_G"
                              , section = Details.Carbohydrates
                              , knownAmount = Just 18.2
                              , referenceAmount = Just 28
                              , guidanceKind = Details.Adequacy
                              , status = Details.PartialData
                              }
                            , { code = "TRANS_FAT_G"
                              , section = Details.Fats
                              , knownAmount = Just 0.4
                              , referenceAmount = Nothing
                              , guidanceKind = Details.Informational
                              , status = Details.Available
                              }
                            ]
                        )
        , test "only a maximum over its limit is dangerous" <|
            \_ ->
                [ nutrient Details.Adequacy (Just 28) Details.MetReference
                , nutrient Details.Informational Nothing Details.Available
                , nutrient Details.Maximum (Just 20) Details.WithinLimit
                , nutrient Details.Maximum (Just 20) Details.OverLimit
                ]
                    |> List.map Details.isDangerous
                    |> Expect.equal [ False, False, False, True ]
        , test "informational nutrients never have progress" <|
            \_ ->
                nutrient Details.Informational Nothing Details.Available
                    |> Details.progressPercent
                    |> Expect.equal Nothing
        , test "progress is absent without a known amount or reference" <|
            \_ ->
                nutrient Details.Adequacy (Just 28) Details.NoData
                    |> withKnownAmount Nothing
                    |> Details.progressPercent
                    |> Expect.equal Nothing
        ]


nutrient : Details.GuidanceKind -> Maybe Float -> Details.NutrientStatus -> Details.Nutrient
nutrient guidanceKind referenceAmount status =
    { code = "FIBER_G"
    , name = "Fiber"
    , section = Details.Carbohydrates
    , knownAmount = Just 28
    , unit = "g"
    , referenceAmount = referenceAmount
    , guidanceKind = guidanceKind
    , itemsWithData = 4
    , coverage = Details.CompleteCoverage
    , status = status
    }


withKnownAmount : Maybe Float -> Details.Nutrient -> Details.Nutrient
withKnownAmount knownAmount item =
    { item | knownAmount = knownAmount }


responseJson : String
responseJson =
    """
    {
      "date": "2026-08-14",
      "reference": {
        "code": "us_fda_dv_adult_2020",
        "name": "FDA Daily Values",
        "authority": "U.S. Food and Drug Administration",
        "jurisdiction": "US",
        "population_label": "Adults and children 4 years and older",
        "source_url": "https://www.fda.gov/example"
      },
      "logged_items": 4,
      "nutrients": [
        {
          "code": "FIBER_G",
          "name": "Fiber",
          "section": "carbohydrates",
          "known_amount": "18.2",
          "unit": "g",
          "reference_amount": "28",
          "guidance_kind": "adequacy",
          "items_with_data": 3,
          "coverage": "partial",
          "status": "partial_data"
        },
        {
          "code": "TRANS_FAT_G",
          "name": "Trans fat",
          "section": "fats",
          "known_amount": 0.4,
          "unit": "g",
          "reference_amount": null,
          "guidance_kind": "informational",
          "items_with_data": 4,
          "coverage": "complete",
          "status": "available"
        }
      ]
    }
    """
