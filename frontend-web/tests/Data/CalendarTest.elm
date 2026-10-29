module Data.CalendarTest exposing (tests)

import Data.Calendar as Calendar
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate exposing (LocalDate)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "Data.Calendar"
        [ fuzz3 offsetFuzzer
            offsetFuzzer
            shiftablePeriodFuzzer
            "shiftMonth is an additive group action"
          <|
            \first second period ->
                Expect.all
                    [ \_ -> Calendar.shiftMonth 0 period |> Expect.equal period
                    , \_ ->
                        Calendar.shiftMonth first (Calendar.shiftMonth second period)
                            |> Expect.equal (Calendar.shiftMonth (first + second) period)
                    , \_ ->
                        Calendar.shiftMonth -first (Calendar.shiftMonth first period)
                            |> Expect.equal period
                    ]
                    ()
        , fuzz calendarPeriodFuzzer
            "monthCells aligns the first weekday and contains exactly the month's days"
          <|
            \period ->
                expectCellsAligned period
        , fuzz calendarPeriodFuzzer
            "monthStart and monthEnd are the valid first and last days of the month"
          <|
            \period ->
                expectMonthBounds period
        , fuzz2 (Fuzz.intRange -3 24)
            shiftablePeriodFuzzer
            "monthsDescending returns count months, or none for non-positive counts"
          <|
            \count period ->
                let
                    months : List String
                    months =
                        Calendar.monthsDescending count period
                in
                if count <= 0 then
                    months |> Expect.equal []

                else
                    Expect.all
                        [ \_ -> List.length months |> Expect.equal count
                        , \_ -> List.head months |> Expect.equal (Just period)
                        , \_ -> expectDescending months
                        ]
                        ()
        , fuzz (SupportFuzz.monthPeriod |> Fuzz.andThen periodAndDayFuzzer)
            "dayKey zero-pads single-digit days and parses back to the same date"
          <|
            \( period, day ) ->
                case monthParts period of
                    Nothing ->
                        Expect.fail ("unexpected invalid month period: " ++ period)

                    Just ( yearValue, month ) ->
                        let
                            key : String
                            key =
                                Calendar.dayKey period day
                        in
                        Expect.all
                            [ \_ -> String.startsWith period key |> Expect.equal True
                            , \_ ->
                                String.endsWith ("-" ++ pad2 day) key |> Expect.equal True
                            , \_ ->
                                String.length key |> Expect.equal (String.length period + 3)
                            , \_ ->
                                LocalDate.fromString key
                                    |> Expect.equal (LocalDate.fromParts yearValue month day)
                            , \_ ->
                                LocalDate.fromString (Calendar.dayKey "1000-01" 1)
                                    |> Expect.equal (LocalDate.fromParts 1000 1 1)
                            , \_ ->
                                LocalDate.fromString (Calendar.dayKey "9999-12" 31)
                                    |> Expect.equal (LocalDate.fromParts 9999 12 31)
                            ]
                            ()
        ]


offsetFuzzer : Fuzzer Int
offsetFuzzer =
    Fuzz.intRange -12 12


shiftablePeriodFuzzer : Fuzzer String
shiftablePeriodFuzzer =
    Fuzz.map2 (\yearValue month -> String.fromInt yearValue ++ "-" ++ pad2 month)
        (Fuzz.intRange 1100 9899)
        (Fuzz.intRange 1 12)


calendarPeriodFuzzer : Fuzzer String
calendarPeriodFuzzer =
    Fuzz.frequency [ ( 5, SupportFuzz.monthPeriod ), ( 1, Fuzz.oneOfValues boundaryPeriods ) ]


periodAndDayFuzzer : String -> Fuzzer ( String, Int )
periodAndDayFuzzer period =
    case monthParts period of
        Just ( yearValue, month ) ->
            Fuzz.map (\day -> ( period, day ))
                (Fuzz.intRange 1 (referenceDaysInMonth yearValue month))

        Nothing ->
            Fuzz.invalid ("invalid month period: " ++ period)


boundaryPeriods : List String
boundaryPeriods =
    [ "1900-02", "2000-02", "2100-02", "2400-02", "1000-01", "9999-12" ]


monthParts : String -> Maybe ( Int, Int )
monthParts period =
    case String.split "-" period of
        [ yearText, monthText ] ->
            Maybe.map2 Tuple.pair (String.toInt yearText) (String.toInt monthText)

        _ ->
            Nothing


referenceDaysInMonth : Int -> Int -> Int
referenceDaysInMonth yearValue month =
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


{-| Sakamoto's day-of-week algorithm, independent of production's Zeller
implementation. The result uses Sunday = 0, matching a Sunday-first grid.
-}
referenceDayOfWeek : Int -> Int -> Int -> Int
referenceDayOfWeek yearValue month day =
    let
        adjustedYear : Int
        adjustedYear =
            if month < 3 then
                yearValue - 1

            else
                yearValue

        monthOffset : Int
        monthOffset =
            case month of
                2 ->
                    3

                3 ->
                    2

                4 ->
                    5

                5 ->
                    0

                6 ->
                    3

                7 ->
                    5

                8 ->
                    1

                9 ->
                    4

                10 ->
                    6

                11 ->
                    2

                12 ->
                    4

                _ ->
                    0
    in
    modBy 7
        (adjustedYear
            + adjustedYear
            // 4
            - adjustedYear
            // 100
            + adjustedYear
            // 400
            + monthOffset
            + day
        )


isLeapYear : Int -> Bool
isLeapYear yearValue =
    (modBy 4 yearValue == 0 && modBy 100 yearValue /= 0) || modBy 400 yearValue == 0


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value


expectCellsAligned : String -> Expect.Expectation
expectCellsAligned period =
    case monthParts period of
        Nothing ->
            Expect.fail ("unexpected invalid month period: " ++ period)

        Just ( yearValue, month ) ->
            let
                days : Int
                days =
                    referenceDaysInMonth yearValue month

                leading : Int
                leading =
                    referenceDayOfWeek yearValue month 1

                trailing : Int
                trailing =
                    modBy 7 (7 - modBy 7 (leading + days))

                cells : List (Maybe Int)
                cells =
                    Calendar.monthCells period
            in
            Expect.all
                [ \_ -> modBy 7 (List.length cells) |> Expect.equal 0
                , \_ -> List.filterMap identity cells |> Expect.equal (List.range 1 days)
                , \_ -> countLeadingNothing cells |> Expect.equal leading
                , \_ -> countTrailingNothing cells |> Expect.equal trailing
                ]
                ()


expectMonthBounds : String -> Expect.Expectation
expectMonthBounds period =
    case monthParts period of
        Nothing ->
            Expect.fail ("unexpected invalid month period: " ++ period)

        Just ( yearValue, month ) ->
            let
                end : Maybe LocalDate
                end =
                    Calendar.monthEnd period
            in
            Expect.all
                [ \_ ->
                    Calendar.monthStart period
                        |> Expect.equal (LocalDate.fromParts yearValue month 1)
                , \_ ->
                    end
                        |> Expect.equal
                            (LocalDate.fromParts yearValue
                                month
                                (referenceDaysInMonth yearValue month)
                            )
                , \_ ->
                    if period == "9999-12" then
                        {- The next period would be 10000-01, outside the
                           canonical four-digit year range.
                        -}
                        Expect.pass

                    else
                        end
                            |> Expect.equal
                                (Calendar.monthStart (Calendar.shiftMonth 1 period)
                                    |> Maybe.map (LocalDate.addDays -1)
                                )
                ]
                ()


countLeadingNothing : List (Maybe Int) -> Int
countLeadingNothing cells =
    case cells of
        Nothing :: rest ->
            1 + countLeadingNothing rest

        _ ->
            0


countTrailingNothing : List (Maybe Int) -> Int
countTrailingNothing cells =
    countLeadingNothing (List.reverse cells)


expectDescending : List String -> Expect.Expectation
expectDescending months =
    List.map2 (\later earlier -> Calendar.shiftMonth 1 earlier == later) months (List.drop 1 months)
        |> List.all identity
        |> Expect.equal True
