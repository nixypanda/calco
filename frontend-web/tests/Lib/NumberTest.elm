module Lib.NumberTest exposing (tests)

import Expect
import Lib.Number as Number
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Lib.Number"
        [ test "toFixed keeps requested trailing zeroes" <|
            \_ ->
                Number.toFixed 1 12
                    |> Expect.equal "12.0"
        , test "toFixedTrimmed removes unneeded fractional zeroes" <|
            \_ ->
                Number.toFixedTrimmed 3 12.5
                    |> Expect.equal "12.5"
        , test "toFixedTrimmed rounds to precision" <|
            \_ ->
                Number.toFixedTrimmed 3 12.3456
                    |> Expect.equal "12.346"
        , test "normalizeDecimalSeparator keeps a trailing comma usable" <|
            \_ ->
                Number.normalizeDecimalSeparator "1,"
                    |> Expect.equal "1."
        , test "normalizeDecimalSeparator leaves grouped values untouched" <|
            \_ ->
                Number.normalizeDecimalSeparator "1.234,5"
                    |> Expect.equal "1.234,5"
        , test "normalizeDecimalSeparator leaves an empty value untouched" <|
            \_ ->
                Number.normalizeDecimalSeparator ""
                    |> Expect.equal ""
        ]
