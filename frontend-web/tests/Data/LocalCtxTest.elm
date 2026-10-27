module Data.LocalCtxTest exposing (tests)

import Data.LocalCtx as LocalCtx
import Expect
import Lib.Date as LocalDate
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.LocalCtx.fromRaw"
        [ test "parses a valid date and keeps the timezone" <|
            \_ ->
                case LocalCtx.fromRaw { date = "2026-06-01", timezone = "Asia/Kolkata" } of
                    Just context ->
                        ( LocalDate.format context.date, context.timezone )
                            |> Expect.equal ( "2026-06-01", "Asia/Kolkata" )

                    Nothing ->
                        Expect.fail "expected a parsed local context"
        , test "rejects an unparseable date" <|
            \_ ->
                LocalCtx.fromRaw { date = "bad-date", timezone = "Asia/Kolkata" }
                    |> Expect.equal Nothing
        ]
