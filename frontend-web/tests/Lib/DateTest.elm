module Lib.DateTest exposing (tests)

import Expect
import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "LocalDate"
        [ test "formats YYYY-MM-DD" <|
            \_ ->
                LocalDate.fromString "2026-06-04"
                    |> Maybe.map LocalDate.format
                    |> Expect.equal (Just "2026-06-04")
        , test "parses valid YYYY-MM-DD" <|
            \_ ->
                LocalDate.fromString "2026-02-28"
                    |> Maybe.map LocalDate.format
                    |> Expect.equal (Just "2026-02-28")
        , fuzz localDateFuzzer "formats and parses dates round trip" <|
            \date ->
                date
                    |> LocalDate.format
                    |> LocalDate.fromString
                    |> Expect.equal (Just date)
        , test "rejects non-date shape" <|
            \_ ->
                LocalDate.fromString "2026/06/04"
                    |> Expect.equal Nothing
        , test "rejects invalid calendar date" <|
            \_ ->
                LocalDate.fromString "2026-02-30"
                    |> Expect.equal Nothing
        , test "prevents next day beyond today" <|
            \_ ->
                Maybe.map2 LocalDate.nextOnOrBefore
                    (LocalDate.fromString "2026-06-04")
                    (LocalDate.fromString "2026-06-04")
                    |> Maybe.andThen identity
                    |> Expect.equal Nothing
        ]


localDateFuzzer : Fuzzer LocalDate.LocalDate
localDateFuzzer =
    Fuzz.map3 dateFromParts
        (Fuzz.intRange 1 9999)
        (Fuzz.intRange 1 12)
        (Fuzz.intRange 1 28)


dateFromParts : Int -> Int -> Int -> LocalDate.LocalDate
dateFromParts year month day =
    case LocalDate.fromParts year month day of
        Just date ->
            date

        Nothing ->
            dateFromParts 2000 1 1
