module Support.Fuzz exposing
    ( interiorLocalDate
    , invalidCanonicalDateStrings
    , localDate
    , monthBoundaryCases
    , year
    )

import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate exposing (LocalDate)


{-| Shared fuzzers for the frontend test suite.

`localDate` deliberately does not filter or fall back with `Maybe.withDefault`.
It builds a year, then a month, then a day whose upper bound comes from an
independent `daysInMonth` calendar, and finally converts through
`LocalDate.fromParts`. If production's calendar disagrees with that independent
calculation, the fuzzer becomes `Fuzz.invalid` with the offending date instead
of silently shrinking to `2000-01-01`.

`interiorLocalDate` is the same generator restricted to years 100..9900, so
adding or subtracting up to 60 days always stays inside the four-digit year
range accepted by `LocalDate.fromString`.

`invalidCanonicalDateStrings` uses the same independent calendar to build, for
a given year, canonical-shaped strings with an impossible month or day for every
month 1..12: day 00 and `daysInMonth + 1`, plus month 00 and month 13 with a
valid day.

`monthBoundaryCases` builds both directions of every month transition for a
given year, using the independent calendar. December of year 9999 is skipped
because its next transition is outside the four-digit year range.

Edge coverage comes from three layers: weighted year buckets (century rules and
the years 1..5 and 9995..9999), a month bucket that makes February about seven
times as likely as any other single month, and an explicit pool of month-end,
leap-day, and year-boundary dates. No `Fuzz.filter` retries are used, so a
rejection always means an intentional calendar disagreement rather than a
generator miss.

-}
localDate : Fuzzer LocalDate
localDate =
    Fuzz.frequency
        [ ( 2, arbitraryLocalDate )
        , ( 1, edgeCaseLocalDate )
        ]


interiorLocalDate : Fuzzer LocalDate
interiorLocalDate =
    interiorYearFuzzer
        |> Fuzz.andThen dateInYear


year : Fuzzer Int
year =
    Fuzz.frequency
        [ ( 6, Fuzz.intRange 1 9999 )
        , ( 3, Fuzz.oneOfValues [ 1, 2, 3, 4, 5, 9995, 9996, 9997, 9998, 9999 ] )
        , ( 2
          , Fuzz.oneOfValues
                [ 100, 400, 1899, 1900, 1901, 1999, 2000, 2001, 2100, 2400 ]
          )
        ]


invalidCanonicalDateStrings : Int -> List String
invalidCanonicalDateStrings yearValue =
    List.concatMap
        (\month ->
            [ canonicalString yearValue month 0
            , canonicalString yearValue month (daysInMonth yearValue month + 1)
            ]
        )
        (List.range 1 12)
        ++ [ canonicalString yearValue 0 15
           , canonicalString yearValue 13 15
           ]


monthBoundaryCases : Int -> List ( String, Int, String )
monthBoundaryCases yearValue =
    List.concatMap
        (\month ->
            let
                lastDay : Int
                lastDay =
                    daysInMonth yearValue month

                nextMonth : Int
                nextMonth =
                    if month == 12 then
                        1

                    else
                        month + 1

                nextYear : Int
                nextYear =
                    if month == 12 then
                        yearValue + 1

                    else
                        yearValue

                last : String
                last =
                    canonicalString yearValue month lastDay

                firstNext : String
                firstNext =
                    canonicalString nextYear nextMonth 1
            in
            if month == 12 && yearValue >= 9999 then
                []

            else
                [ ( last, 1, firstNext )
                , ( firstNext, -1, last )
                ]
        )
        (List.range 1 12)


canonicalString : Int -> Int -> Int -> String
canonicalString yearValue month day =
    pad4 yearValue ++ "-" ++ pad2 month ++ "-" ++ pad2 day


arbitraryLocalDate : Fuzzer LocalDate
arbitraryLocalDate =
    year
        |> Fuzz.andThen dateInYear


dateInYear : Int -> Fuzzer LocalDate
dateInYear yearValue =
    monthFuzzer
        |> Fuzz.andThen
            (\month ->
                Fuzz.intRange 1 (daysInMonth yearValue month)
                    |> Fuzz.andThen (expectLocalDate yearValue month)
            )


edgeCaseLocalDate : Fuzzer LocalDate
edgeCaseLocalDate =
    Fuzz.oneOfValues edgeCaseParts
        |> Fuzz.andThen
            (\( yearValue, month, day ) ->
                expectLocalDate yearValue month day
            )


edgeCaseParts : List ( Int, Int, Int )
edgeCaseParts =
    [ ( 2024, 1, 31 )
    , ( 2024, 2, 28 )
    , ( 2024, 2, 29 )
    , ( 2023, 2, 28 )
    , ( 2000, 2, 29 )
    , ( 1900, 2, 28 )
    , ( 2024, 3, 1 )
    , ( 2024, 12, 31 )
    , ( 1, 1, 1 )
    , ( 1, 12, 31 )
    , ( 9999, 1, 1 )
    , ( 9999, 12, 31 )
    , ( 100, 2, 28 )
    , ( 400, 2, 29 )
    ]


interiorYearFuzzer : Fuzzer Int
interiorYearFuzzer =
    Fuzz.frequency
        [ ( 6, Fuzz.intRange 100 9900 )
        , ( 2
          , Fuzz.oneOfValues
                [ 100, 101, 400, 1899, 1900, 2000, 2001, 2400, 9899, 9900 ]
          )
        ]


monthFuzzer : Fuzzer Int
monthFuzzer =
    Fuzz.frequency
        [ ( 4, Fuzz.intRange 1 12 )
        , ( 2, Fuzz.constant 2 )
        ]


expectLocalDate : Int -> Int -> Int -> Fuzzer LocalDate
expectLocalDate yearValue month day =
    if day < 1 || day > daysInMonth yearValue month then
        Fuzz.invalid (invalidMessage "independent calendar rejects" yearValue month day)

    else
        case LocalDate.fromParts yearValue month day of
            Just date ->
                Fuzz.constant date

            Nothing ->
                Fuzz.invalid (invalidMessage "LocalDate.fromParts rejects" yearValue month day)


invalidMessage : String -> Int -> Int -> Int -> String
invalidMessage reason yearValue month day =
    "Support.Fuzz: "
        ++ reason
        ++ " "
        ++ String.fromInt yearValue
        ++ "-"
        ++ pad2 month
        ++ "-"
        ++ pad2 day


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value


pad4 : Int -> String
pad4 value =
    let
        raw : String
        raw =
            String.fromInt value
    in
    String.repeat (max 0 (4 - String.length raw)) "0" ++ raw


daysInMonth : Int -> Int -> Int
daysInMonth yearValue month =
    case month of
        1 ->
            31

        2 ->
            if isLeapYear yearValue then
                29

            else
                28

        3 ->
            31

        4 ->
            30

        5 ->
            31

        6 ->
            30

        7 ->
            31

        8 ->
            31

        9 ->
            30

        10 ->
            31

        11 ->
            30

        12 ->
            31

        _ ->
            0


isLeapYear : Int -> Bool
isLeapYear yearValue =
    (modBy 4 yearValue == 0 && modBy 100 yearValue /= 0) || modBy 400 yearValue == 0
