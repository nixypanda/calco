module Data.LogSummaryTest exposing (tests)

import Data.LogSummary as LogSummary
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Data.LogSummary"
        [ describe "fromLogs"
            [ test "adds up the four macro codes across a day's logs" <|
                \_ ->
                    LogSummary.fromLogs day
                        [ { nutrients =
                                [ amount "ENERGY_KCAL" "200.5"
                                , amount "PROTEIN_G" "10"
                                , amount "CARBS_G" "30"
                                , amount "FAT_G" "5"
                                ]
                          }
                        , { nutrients =
                                [ amount "ENERGY_KCAL" "99.5"
                                , amount "PROTEIN_G" "5"
                                , amount "CARBS_G" "1"
                                , amount "FAT_G" "2"
                                ]
                          }
                        ]
                        |> Expect.equal
                            (Just
                                { date = day
                                , energyKcal = 300
                                , proteinG = 15
                                , carbsG = 31
                                , fatG = 7
                                }
                            )
            , test "ignores nutrients that are not macros" <|
                \_ ->
                    LogSummary.fromLogs day
                        [ { nutrients = [ amount "FIBER_G" "4" ] } ]
                        |> Maybe.map .energyKcal
                        |> Expect.equal (Just 0)
            , test "a day with nothing logged has no summary" <|
                \_ ->
                    LogSummary.fromLogs day []
                        |> Expect.equal Nothing
            ]
        ]


amount : String -> String -> { code : String, amount : String, unit : String }
amount code value =
    { code = code, amount = value, unit = "g" }


day : LocalDate
day =
    case LocalDate.fromString "2026-08-20" of
        Just value ->
            value

        Nothing ->
            LocalDate.fromPosix Time.utc (Time.millisToPosix 0)
