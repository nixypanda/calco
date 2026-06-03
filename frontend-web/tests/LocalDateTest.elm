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
        , test "rejects non-date shape" <|
            \_ ->
                LocalDate.fromString "2026/06/04"
                    |> Expect.equal Nothing
        ]
