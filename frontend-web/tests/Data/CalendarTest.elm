module Data.CalendarTest exposing (tests)

import Data.Calendar as Calendar
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate exposing (LocalDate)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3, test)


tests : Test
tests =
    describe "Data.Calendar"
        [ describe "shiftMonth"
            [ fuzz shiftablePeriodFuzzer "shifting by zero is identity" <|
                \period ->
                    Calendar.shiftMonth 0 period
                        |> Expect.equal period
            , fuzz2 offsetFuzzer shiftablePeriodFuzzer "shifting by n then -n is identity" <|
                \offset period ->
                    Calendar.shiftMonth offset (Calendar.shiftMonth -offset period)
                        |> Expect.equal period
            , fuzz3 offsetFuzzer offsetFuzzer shiftablePeriodFuzzer "shifts compose additively" <|
                \first second period ->
                    Calendar.shiftMonth first (Calendar.shiftMonth second period)
                        |> Expect.equal (Calendar.shiftMonth (first + second) period)
            ]
        , describe "monthCells"
            [ fuzz SupportFuzz.monthPeriod "aligns cells to the independent first weekday" <|
                \period ->
                    expectCellsAligned period
            , test "century and year-boundary periods align independently" <|
                \_ ->
                    Expect.all
                        (List.map (\period _ -> expectCellsAligned period) boundaryPeriods)
                        ()
            ]
        , describe "month boundaries"
            [ fuzz SupportFuzz.monthPeriod "monthStart is the first day of the month" <|
                \period ->
                    case monthParts period of
                        Nothing ->
                            Expect.fail ("unexpected invalid month period: " ++ period)

                        Just ( yearValue, month ) ->
                            Calendar.monthStart period
                                |> Expect.equal (LocalDate.fromParts yearValue month 1)
            , fuzz SupportFuzz.monthPeriod "monthEnd is the day before the next month starts" <|
                \period ->
                    if period == "9999-12" then
                        {- The next period would be 10000-01, outside the canonical
                           four-digit year range, so there is no next monthStart to compare.
                        -}
                        Expect.pass

                    else
                        let
                            expected : Maybe LocalDate
                            expected =
                                Calendar.monthStart (Calendar.shiftMonth 1 period)
                                    |> Maybe.map (LocalDate.addDays -1)
                        in
                        Calendar.monthEnd period
                            |> Expect.equal expected
            , test "century and year-boundary periods have direct start and end dates" <|
                \_ ->
                    Expect.all
                        (List.map (\period _ -> expectMonthBounds period) boundaryPeriods)
                        ()
            ]
        , describe "monthsDescending"
            [ fuzz2
                (Fuzz.intRange 1 24)
                shiftablePeriodFuzzer
                "returns count months starting at the requested month"
              <|
                \count period ->
                    let
                        months : List String
                        months =
                            Calendar.monthsDescending count period
                    in
                    Expect.all
                        [ \_ -> List.length months |> Expect.equal count
                        , \_ -> List.head months |> Expect.equal (Just period)
                        , \_ -> expectDescending months
                        ]
                        ()
            , fuzz2
                (Fuzz.intRange -50 0)
                shiftablePeriodFuzzer
                "a non-positive count returns no months"
              <|
                \count period ->
                    Calendar.monthsDescending count period
                        |> Expect.equal []
            ]
        , describe "dayKey"
            [ fuzz2
                SupportFuzz.monthPeriod
                (Fuzz.intRange 1 9)
                "single-digit days are zero-padded"
              <|
                \period day ->
                    let
                        key : String
                        key =
                            Calendar.dayKey period day
                    in
                    Expect.all
                        [ \_ -> String.startsWith period key |> Expect.equal True
                        , \_ ->
                            String.endsWith ("-0" ++ String.fromInt day) key
                                |> Expect.equal True
                        , \_ -> String.length key |> Expect.equal (String.length period + 3)
                        ]
                        ()
            , fuzz
                (SupportFuzz.monthPeriod |> Fuzz.andThen periodAndDayFuzzer)
                "dayKey parses back to the same date"
              <|
                \( period, day ) ->
                    case monthParts period of
                        Nothing ->
                            Expect.fail ("unexpected invalid month period: " ++ period)

                        Just ( yearValue, month ) ->
                            LocalDate.fromString (Calendar.dayKey period day)
                                |> Expect.equal (LocalDate.fromParts yearValue month day)
            , test "year-boundary periods parse at their first and last days" <|
                \_ ->
                    Expect.all
                        [ \_ ->
                            LocalDate.fromString (Calendar.dayKey "1000-01" 1)
                                |> Expect.equal (LocalDate.fromParts 1000 1 1)
                        , \_ ->
                            LocalDate.fromString (Calendar.dayKey "9999-12" 31)
                                |> Expect.equal (LocalDate.fromParts 9999 12 31)
                        ]
                        ()
            ]
        ]



-- Fuzzers


offsetFuzzer : Fuzzer Int
offsetFuzzer =
    Fuzz.intRange -12 12


shiftablePeriodFuzzer : Fuzzer String
shiftablePeriodFuzzer =
    Fuzz.map2
        (\yearValue month ->
            String.fromInt yearValue ++ "-" ++ pad2 month
        )
        (Fuzz.intRange 1100 9899)
        (Fuzz.intRange 1 12)


periodAndDayFuzzer : String -> Fuzzer ( String, Int )
periodAndDayFuzzer period =
    case monthParts period of
        Just ( yearValue, month ) ->
            Fuzz.map
                (\day -> ( period, day ))
                (Fuzz.intRange 1 (referenceDaysInMonth yearValue month))

        Nothing ->
            Fuzz.invalid ("invalid month period: " ++ period)



-- References and assertions


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
            Expect.all
                [ \_ ->
                    Calendar.monthStart period
                        |> Expect.equal (LocalDate.fromParts yearValue month 1)
                , \_ ->
                    Calendar.monthEnd period
                        |> Expect.equal
                            (LocalDate.fromParts
                                yearValue
                                month
                                (referenceDaysInMonth yearValue month)
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
    List.map2
        (\later earlier -> Calendar.shiftMonth 1 earlier == later)
        months
        (List.drop 1 months)
        |> List.all identity
        |> Expect.equal True
