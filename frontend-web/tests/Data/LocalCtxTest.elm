module Data.LocalCtxTest exposing (tests)

import Data.LocalCtx as LocalCtx
import Expect
import Fuzz
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Data.LocalCtx.fromRaw"
        [ fuzz (Fuzz.map2 Tuple.pair Support.year Support.segment)
            "invalid canonical date strings are rejected"
          <|
            \( year, timezone ) ->
                Support.invalidCanonicalDateStrings year
                    |> List.map
                        (\raw ->
                            LocalCtx.fromRaw { date = raw, timezone = timezone }
                                |> Expect.equal Nothing
                        )
                    |> expectAll
        ]


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()
