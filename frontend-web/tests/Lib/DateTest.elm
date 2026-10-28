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
        [ fuzz3 Support.Fuzz.localDate
            (Fuzz.intRange -400 400)
            (Fuzz.intRange 1 400)
            "addDays is a group action with strict ordering and exact month rollover"
          <|
            \date offset delta ->
                Expect.all
                    [ \_ -> LocalDate.addDays 0 date |> Expect.equal date
                    , \_ ->
                        LocalDate.addDays offset (LocalDate.addDays -offset date)
                            |> Expect.equal date
                    , \_ ->
                        LocalDate.addDays offset (LocalDate.addDays delta date)
                            |> Expect.equal (LocalDate.addDays (offset + delta) date)
                    , \_ ->
                        LocalDate.compare
                            (LocalDate.addDays offset date)
                            (LocalDate.addDays (offset + delta) date)
                            |> Expect.equal LT
                    , \_ ->
                        [ 1900, 2000, 2023, 2024 ]
                            |> List.concatMap Support.Fuzz.monthBoundaryCases
                            |> List.all
                                (\( start, step, expected ) ->
                                    LocalDate.fromString start
                                        |> Maybe.map (LocalDate.addDays step >> LocalDate.format)
                                        |> (==) (Just expected)
                                )
                            |> Expect.equal True
                    ]
                    ()
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "nextOnOrBefore is the next day exactly when it is not after today"
          <|
            \today current ->
                case LocalDate.nextOnOrBefore today current of
                    Nothing ->
                        LocalDate.compare current today |> Expect.notEqual LT

                    Just next ->
                        Expect.all
                            [ \_ -> LocalDate.compare current today |> Expect.equal LT
                            , \_ -> LocalDate.addDays 1 current |> Expect.equal next
                            , \_ -> LocalDate.compare next today |> Expect.notEqual GT
                            ]
                            ()
        , fuzz2 Support.Fuzz.localDate
            Support.Fuzz.localDate
            "clampTo is an idempotent upper bound"
          <|
            \maximum date ->
                let
                    clamped : LocalDate
                    clamped =
                        LocalDate.clampTo maximum date
                in
                Expect.all
                    [ \_ -> LocalDate.clampTo maximum clamped |> Expect.equal clamped
                    , \_ -> LocalDate.compare clamped maximum |> Expect.notEqual GT
                    , \_ ->
                        LocalDate.clampTo maximum date
                            |> Expect.equal
                                (if LocalDate.compare date maximum == GT then
                                    maximum

                                 else
                                    date
                                )
                    ]
                    ()
        , fuzz Support.Fuzz.localDate
            "format emits canonical YYYY-MM-DD and fromString inverts it"
          <|
            \date ->
                let
                    formatted : String
                    formatted =
                        LocalDate.format date
                in
                Expect.all
                    [ \_ -> String.length formatted |> Expect.equal 10
                    , \_ ->
                        ( String.slice 4 5 formatted, String.slice 7 8 formatted )
                            |> Expect.equal ( "-", "-" )
                    , \_ ->
                        String.all (\char -> Char.isDigit char || char == '-') formatted
                            |> Expect.equal True
                    , \_ -> LocalDate.fromString formatted |> Expect.equal (Just date)
                    ]
                    ()
        , fuzz nearMissDateString "fromString rejects non-canonical date-like strings" <|
            \raw ->
                LocalDate.fromString raw |> Expect.equal Nothing
        , fuzz Support.Fuzz.year
            "fromString rejects calendar-invalid dates and applies the Gregorian leap rule"
          <|
            \yearValue ->
                Expect.all
                    [ \_ ->
                        Support.Fuzz.invalidCanonicalDateStrings yearValue
                            |> List.all (\raw -> LocalDate.fromString raw == Nothing)
                            |> Expect.equal True
                    , \_ ->
                        (LocalDate.fromString (pad4 yearValue ++ "-02-29") /= Nothing)
                            |> Expect.equal (isLeapYear yearValue)
                    ]
                    ()
        ]


nearMissDateString : Fuzzer String
nearMissDateString =
    let
        fromDate : (String -> String) -> Fuzzer String
        fromDate change =
            Fuzz.map (LocalDate.format >> change) Support.Fuzz.localDate
    in
    Fuzz.oneOf
        [ fromDate (String.dropLeft 1)
        , fromDate ((++) "0")
        , fromDate (String.replace "-" "/")
        , fromDate (\formatted -> formatted ++ " ")
        , fromDate (String.dropRight 1)
        , fromDate (\formatted -> formatted ++ "T00:00:00")
        , Fuzz.map2
            (\yearValue month -> pad4 yearValue ++ "-" ++ String.fromInt month ++ "-01")
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 9)
        , Fuzz.map2
            (\yearValue day -> pad4 yearValue ++ "-01-" ++ String.fromInt day)
            (Fuzz.intRange 1 9999)
            (Fuzz.intRange 1 9)
        ]


pad4 : Int -> String
pad4 value =
    String.padLeft 4 '0' (String.fromInt value)


isLeapYear : Int -> Bool
isLeapYear yearValue =
    (modBy 4 yearValue == 0 && modBy 100 yearValue /= 0) || modBy 400 yearValue == 0
