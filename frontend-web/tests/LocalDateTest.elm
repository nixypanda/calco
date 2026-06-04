module LocalDateTest exposing (tests)

import Data.LocalDate as LocalDate
import Expect
import Test exposing (Test, describe, test)


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
        , test "produces stable diary route query strings" <|
            \_ ->
                LocalDate.fromString "2026-06-04"
                    |> Maybe.map LocalDate.routeQuery
                    |> Expect.equal (Just "date=2026-06-04")
        ]
