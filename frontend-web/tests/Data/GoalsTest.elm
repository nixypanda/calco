module Data.GoalsTest exposing (tests)

import Api.Goals
import Data.Goals as Goals exposing (GoalSource(..))
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.Goals"
        [ test "decoder handles default goals" <|
            \_ ->
                Decode.decodeString Goals.decoder
                    """
                    {
                      "requested_date": "2026-06-16",
                      "effective_from": null,
                      "source": "default",
                      "calorie_target": "2100",
                      "protein_target_g": "150",
                      "carbs_target_g": "240",
                      "fat_target_g": "60"
                    }
                    """
                    |> Expect.equal
                        (Ok
                            { requestedDate = date "2026-06-16"
                            , effectiveFrom = Nothing
                            , source = Default
                            , targets =
                                { calorieTarget = 2100
                                , proteinTargetG = 150
                                , carbsTargetG = 240
                                , fatTargetG = 60
                                }
                            }
                        )
        , test "decoder handles saved goals" <|
            \_ ->
                Decode.decodeString Goals.decoder
                    """
                    {
                      "requested_date": "2026-06-16",
                      "effective_from": "2026-06-10",
                      "source": "saved",
                      "calorie_target": "2290",
                      "protein_target_g": "160",
                      "carbs_target_g": "255",
                      "fat_target_g": "70"
                    }
                    """
                    |> Expect.equal
                        (Ok
                            { requestedDate = date "2026-06-16"
                            , effectiveFrom = Just (date "2026-06-10")
                            , source = Saved
                            , targets =
                                { calorieTarget = 2290
                                , proteinTargetG = 160
                                , carbsTargetG = 255
                                , fatTargetG = 70
                                }
                            }
                        )
        , test "saveGoalRequestEncoder includes device context and numeric fields" <|
            \_ ->
                Api.Goals.saveGoalRequestEncoder
                    { localDate = date "2026-06-16"
                    , deviceTimezone = "Asia/Kolkata"
                    , targets =
                        { calorieTarget = 2100
                        , proteinTargetG = 150
                        , carbsTargetG = 240
                        , fatTargetG = 60
                        }
                    }
                    |> Encode.encode 0
                    |> Expect.equal
                        (String.concat
                            [ "{\"local_date\":\"2026-06-16\""
                            , ",\"device_timezone\":\"Asia/Kolkata\""
                            , ",\"calorie_target\":2100"
                            , ",\"protein_target_g\":150"
                            , ",\"carbs_target_g\":240"
                            , ",\"fat_target_g\":60}"
                            ]
                        )
        ]


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            case LocalDate.fromParts 1970 1 1 of
                Just fallback ->
                    fallback

                Nothing ->
                    date "1970-01-01"
