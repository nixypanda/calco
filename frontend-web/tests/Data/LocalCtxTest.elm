module Data.LocalCtxTest exposing (tests)

import Data.LocalCtx as LocalCtx
import Expect
import Lib.Date as LocalDate
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz3)


tests : Test
tests =
    describe "Data.LocalCtx.fromRaw"
        [ fuzz3
            Support.localDate
            Support.year
            Support.segment
            "fromRaw roundtrips canonical dates and rejects invalid ones"
          <|
            \date yearValue timezone ->
                Expect.all
                    [ \_ ->
                        LocalCtx.fromRaw
                            { date = LocalDate.format date, timezone = timezone }
                            |> Expect.equal (Just { date = date, timezone = timezone })
                    , \_ ->
                        Support.invalidCanonicalDateStrings yearValue
                            |> List.all
                                (\raw ->
                                    LocalCtx.fromRaw { date = raw, timezone = timezone }
                                        == Nothing
                                )
                            |> Expect.equal True
                    ]
                    ()
        ]
