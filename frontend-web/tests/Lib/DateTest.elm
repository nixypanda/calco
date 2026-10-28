module Lib.DateTest exposing (tests)

import Char
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate exposing (LocalDate)
import Support.Fuzz
import Test exposing (Test, describe, fuzz, fuzz2, fuzz3)


tests : Test
tests =
    describe "LocalDate"
        [ fuzz Support.Fuzz.localDate "addDays 0 is the identity" <|
            \date ->
                LocalDate.addDays 0 date
                    |> LocalDate.equals date
                    |> Expect.equal True
        , fuzz3 Support.Fuzz.localDate
            (Fuzz.intRange -400 400)
            (Fuzz.intRange -400 400)
            "addDays is associative (a group action)"
          <|
            \date first second ->
                LocalDate.addDays first (LocalDate.addDays second date)
                    |> LocalDate.equals (LocalDate.addDays (first + second) date)
                    |> Expect.equal True
        , fuzz2 Support.Fuzz.localDate
            (Fuzz.intRange 0 800)
            "addDays n then addDays -n is the identity"
          <|
            \date offset ->
                LocalDate.addDays -offset (LocalDate.addDays offset date)
                    |> LocalDate.equals date
                    |> Expect.equal True
        , fuzz3 Support.Fuzz.localDate
            (Fuzz.intRange -400 400)
            (Fuzz.intRange 1 400)
            "addDays preserves strict date order"
          <|
            \date first delta ->
                LocalDate.compare
                    (LocalDate.addDays first date)
                    (LocalDate.addDays (first + delta) date)
                    |> Expect.equal LT
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "equals agrees with compare EQ and formatted-date equality"
          <|
            \left right ->
                Expect.all
                    [ \_ ->
                        LocalDate.equals left right
                            |> Expect.equal (LocalDate.compare left right == EQ)
                    , \_ ->
                        LocalDate.equals left right
                            |> Expect.equal (LocalDate.format left == LocalDate.format right)
                    , \_ ->
                        LocalDate.equals left left
                            |> Expect.equal True
                    ]
                    ()
        , fuzz2 Support.Fuzz.interiorLocalDate
            (Fuzz.intRange -60 60)
            "addDays stays parseable by fromString inside four-digit years"
          <|
            \date offset ->
                let
                    shifted : LocalDate
                    shifted =
                        LocalDate.addDays offset date
                in
                LocalDate.fromString (LocalDate.format shifted)
                    |> Expect.equal (Just shifted)
        , fuzz Support.Fuzz.year
            "addDays follows the Gregorian calendar at every month boundary"
          <|
            \yearValue ->
                Support.Fuzz.monthBoundaryCases yearValue
                    |> List.map checkMonthBoundary
                    |> expectAll
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "nextOnOrBefore returns Nothing iff current is not before today"
          <|
            \today current ->
                case LocalDate.nextOnOrBefore today current of
                    Nothing ->
                        LocalDate.compare current today
                            |> Expect.notEqual LT

                    Just next ->
                        Expect.all
                            [ \_ ->
                                LocalDate.compare current today
                                    |> Expect.equal LT
                            , \_ ->
                                LocalDate.equals next (LocalDate.addDays 1 current)
                                    |> Expect.equal True
                            , \_ ->
                                LocalDate.compare next today
                                    |> Expect.notEqual GT
                            ]
                            ()
        , fuzz2 Support.Fuzz.localDate Support.Fuzz.localDate "clampTo is idempotent" <|
            \maximum date ->
                LocalDate.clampTo maximum (LocalDate.clampTo maximum date)
                    |> LocalDate.equals (LocalDate.clampTo maximum date)
                    |> Expect.equal True
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "clampTo returns exactly maximum above the bound and date otherwise"
          <|
            \maximum date ->
                let
                    expected : LocalDate
                    expected =
                        if LocalDate.compare date maximum == GT then
                            maximum

                        else
                            date
                in
                LocalDate.clampTo maximum date
                    |> LocalDate.format
                    |> Expect.equal (LocalDate.format expected)
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "clampTo leaves dates at or below the bound unchanged"
          <|
            \maximum date ->
                case LocalDate.compare date maximum of
                    GT ->
                        Expect.pass

                    _ ->
                        LocalDate.clampTo maximum date
                            |> LocalDate.equals date
                            |> Expect.equal True
        , fuzz Support.Fuzz.localDate "format emits canonical zero-padded YYYY-MM-DD" <|
            \date ->
                canonicalFormatExpectation (LocalDate.format date)
        , fuzz Support.Fuzz.localDate "fromString (format date) is Just date" <|
            \date ->
                case LocalDate.fromString (LocalDate.format date) of
                    Just parsed ->
                        LocalDate.equals parsed date
                            |> Expect.equal True

                    Nothing ->
                        Expect.fail ("fromString rejected " ++ LocalDate.format date)
        , fuzz (Fuzz.stringOfLengthBetween 0 15)
            "fromString accepts only canonical zero-padded YYYY-MM-DD"
          <|
            \raw ->
                case LocalDate.fromString raw of
                    Nothing ->
                        Expect.pass

                    Just date ->
                        LocalDate.format date
                            |> Expect.equal raw
        , fuzz nearMissDateString "fromString rejects non-canonical date-like strings" <|
            \raw ->
                LocalDate.fromString raw
                    |> Expect.equal Nothing
        , fuzz Support.Fuzz.year
            "fromString rejects calendar-invalid dates for every month"
          <|
            \yearValue ->
                Support.Fuzz.invalidCanonicalDateStrings yearValue
                    |> List.map
                        (\raw ->
                            LocalDate.fromString raw
                                |> Expect.equal Nothing
                        )
                    |> expectAll
        , fuzz leapRuleYear "fromString applies the Gregorian leap-year rule to February 29" <|
            \year ->
                let
                    raw : String
                    raw =
                        pad4 year ++ "-02-29"

                    accepted : Bool
                    accepted =
                        LocalDate.fromString raw /= Nothing
                in
                accepted
                    |> Expect.equal (isLeapYear year)
        ]


canonicalFormatExpectation : String -> Expect.Expectation
canonicalFormatExpectation formatted =
    case String.split "-" formatted of
        [ year, month, day ] ->
            Expect.all
                [ \_ -> String.length formatted |> Expect.equal 10
                , \_ -> String.length year |> Expect.equal 4
                , \_ -> String.length month |> Expect.equal 2
                , \_ -> String.length day |> Expect.equal 2
                , \_ -> String.all Char.isDigit year |> Expect.equal True
                , \_ -> String.all Char.isDigit month |> Expect.equal True
                , \_ -> String.all Char.isDigit day |> Expect.equal True
                ]
                ()

        _ ->
            Expect.fail ("expected YYYY-MM-DD, got " ++ formatted)


nearMissDateString : Fuzzer String
nearMissDateString =
    Fuzz.oneOf
        [ Fuzz.map2
            (\date variant -> mutateDateString variant (LocalDate.format date))
            Support.Fuzz.localDate
            (Fuzz.intRange 0 8)
        , Fuzz.map2
            (\yearValue month -> pad4 yearValue ++ "-" ++ String.fromInt month ++ "-01")
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 9)
        , Fuzz.map2
            (\yearValue day -> pad4 yearValue ++ "-01-" ++ String.fromInt day)
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 9)
        , Fuzz.map2
            (\yearValue month -> pad4 yearValue ++ "-0" ++ pad2 month ++ "-01")
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 12)
        , Fuzz.map2
            (\yearValue day -> pad4 yearValue ++ "-01-0" ++ pad2 day)
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 31)
        ]


mutateDateString : Int -> String -> String
mutateDateString variant formatted =
    case variant of
        0 ->
            String.dropLeft 1 formatted

        1 ->
            "0" ++ formatted

        2 ->
            String.replace "-" "/" formatted

        3 ->
            String.replace "-" "" formatted

        4 ->
            " " ++ formatted

        5 ->
            formatted ++ " "

        6 ->
            String.dropRight 1 formatted

        7 ->
            "+" ++ formatted

        _ ->
            formatted ++ "T00:00:00"


checkMonthBoundary : ( String, Int, String ) -> Expect.Expectation
checkMonthBoundary ( start, offset, expected ) =
    case LocalDate.fromString start of
        Just date ->
            LocalDate.addDays offset date
                |> LocalDate.format
                |> Expect.equal expected

        Nothing ->
            Expect.fail ("failed to parse boundary case start date: " ++ start)


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    case expectations of
        [] ->
            Expect.fail "expected at least one expectation"

        _ ->
            Expect.all
                (List.map (\expectation _ -> expectation) expectations)
                ()


leapRuleYear : Fuzzer Int
leapRuleYear =
    Fuzz.frequency
        [ ( 3, Fuzz.intRange 1 9999 )
        , ( 2
          , Fuzz.oneOfValues
                [ 1, 4, 100, 400, 1899, 1900, 1901, 1999, 2000, 2001, 2100, 2400, 9999 ]
          )
        ]


pad4 : Int -> String
pad4 value =
    let
        raw : String
        raw =
            String.fromInt value
    in
    String.repeat (max 0 (4 - String.length raw)) "0" ++ raw


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value


isLeapYear : Int -> Bool
isLeapYear year =
    (modBy 4 year == 0 && modBy 100 year /= 0) || modBy 400 year == 0
