module Ui.MonthCalendarTest exposing (tests)

{-| The calendar skeleton and the loaded grid share `monthRows`, so a wrong
partition is a real layout bug rather than a presentation detail. This property
pins the shared row shape; the browser harness owns cell geometry.
-}

import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz)
import Ui.MonthCalendar as MonthCalendar


tests : Test
tests =
    describe "Ui.MonthCalendar.monthRows"
        [ fuzz calendarPeriodFuzzer
            "partitions every month into 4-6 complete weeks with all its days"
          <|
            \period ->
                let
                    rows : List (List (Maybe Int))
                    rows =
                        MonthCalendar.monthRows period

                    rowCount : Int
                    rowCount =
                        List.length rows

                    days : Int
                    days =
                        referenceDaysInMonth period
                in
                Expect.all
                    [ \_ ->
                        (rowCount >= 4 && rowCount <= 6)
                            |> Expect.equal True
                    , \_ ->
                        List.all (\row -> List.length row == 7) rows
                            |> Expect.equal True
                    , \_ ->
                        List.concat rows
                            |> List.filterMap identity
                            |> Expect.equal (List.range 1 days)
                    ]
                    ()
        ]


calendarPeriodFuzzer : Fuzzer String
calendarPeriodFuzzer =
    Fuzz.frequency
        [ ( 5, SupportFuzz.monthPeriod )
        , ( 1
          , Fuzz.oneOfValues
                [ "2026-02"
                , "2026-03"
                , "2026-08"
                ]
          )
        ]


referenceDaysInMonth : String -> Int
referenceDaysInMonth period =
    case String.split "-" period of
        [ yearText, monthText ] ->
            case ( String.toInt yearText, String.toInt monthText ) of
                ( Just yearValue, Just month ) ->
                    daysInMonth yearValue month

                _ ->
                    0

        _ ->
            0


daysInMonth : Int -> Int -> Int
daysInMonth yearValue month =
    case month of
        2 ->
            if isLeapYear yearValue then
                29

            else
                28

        4 ->
            30

        6 ->
            30

        9 ->
            30

        11 ->
            30

        _ ->
            31


isLeapYear : Int -> Bool
isLeapYear yearValue =
    (modBy 4 yearValue == 0 && modBy 100 yearValue /= 0) || modBy 400 yearValue == 0
