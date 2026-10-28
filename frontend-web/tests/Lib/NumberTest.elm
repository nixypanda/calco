module Lib.NumberTest exposing (tests)

import Char
import Expect
import Fuzz exposing (Fuzzer)
import Lib.Number as Number
import Test exposing (Test, describe, fuzz, fuzz2)


tests : Test
tests =
    describe "Lib.Number"
        [ fuzz2 nonNegativeValue
            precision
            "toFixed parses back within half a unit in the last place"
          <|
            \value digits ->
                let
                    formatted : String
                    formatted =
                        Number.toFixed digits value

                    -- The half-unit term is the actual rounding law. The extra
                    -- 1e-9 only absorbs double rounding in the multiply/round/
                    -- divide path for values up to one million.
                    tolerance : Float
                    tolerance =
                        0.5 / (10 ^ toFloat digits) + 1.0e-9
                in
                case String.toFloat formatted of
                    Just parsed ->
                        parsed
                            |> Expect.within (Expect.Absolute tolerance) value

                    Nothing ->
                        Expect.fail ("toFixed produced a non-numeric string: " ++ formatted)
        , fuzz2 nonNegativeValue
            (Fuzz.intRange 1 6)
            "toFixed emits exactly the requested fractional digits"
          <|
            \value digits ->
                case String.split "." (Number.toFixed digits value) of
                    [ whole, fractional ] ->
                        Expect.all
                            [ \_ -> String.length fractional |> Expect.equal digits
                            , \_ -> String.all Char.isDigit fractional |> Expect.equal True
                            , \_ -> String.isEmpty whole |> Expect.equal False
                            , \_ -> String.all Char.isDigit whole |> Expect.equal True
                            ]
                            ()

                    _ ->
                        Expect.fail "expected a single decimal point"
        , fuzz2 nonNegativeValue
            precision
            "toFixedTrimmed parses like toFixed without trailing zeros or dot"
          <|
            \value digits ->
                let
                    formatted : String
                    formatted =
                        Number.toFixed digits value

                    trimmed : String
                    trimmed =
                        Number.toFixedTrimmed digits value
                in
                Expect.all
                    [ \_ -> String.toFloat trimmed |> Expect.equal (String.toFloat formatted)
                    , \_ ->
                        if String.contains "." trimmed then
                            Expect.all
                                [ \_ -> String.endsWith "." trimmed |> Expect.equal False
                                , \_ -> String.endsWith "0" trimmed |> Expect.equal False
                                ]
                                ()

                        else
                            Expect.pass
                    ]
                    ()
        , fuzz (Fuzz.map (\raw -> raw ++ ".") Fuzz.string)
            "normalizeDecimalSeparator leaves inputs containing a dot unchanged"
          <|
            \raw ->
                Number.normalizeDecimalSeparator raw
                    |> Expect.equal raw
        , fuzz loneCommaInput "normalizeDecimalSeparator rewrites a lone comma to a dot" <|
            \raw ->
                Number.normalizeDecimalSeparator raw
                    |> Expect.equal (String.replace "," "." raw)
        , fuzz withoutLoneComma "normalizeDecimalSeparator leaves zero or many commas unchanged" <|
            \raw ->
                Number.normalizeDecimalSeparator raw
                    |> Expect.equal raw
        , fuzz (Fuzz.oneOf [ Fuzz.string, commaInput ])
            "normalizeDecimalSeparator is idempotent"
          <|
            \raw ->
                Number.normalizeDecimalSeparator (Number.normalizeDecimalSeparator raw)
                    |> Expect.equal (Number.normalizeDecimalSeparator raw)
        ]


{-| `toFixed` is only specified for non-negative values in this phase; its
negative branch is a known separate production risk.

The domain stops at one million. Widening it to 10^9 keeps the scaled integer
(10^15 at precision 6) below 2^53, but the source value's ULP there is about
1.2e-7. An exact half-unit tie can then round to a double whose distance from
the source exceeds the 1e-9 representation slack: for example
`363593900.9862655` at precision 6 lands 5.36e-7 away, above the 5.01e-7
half-unit tolerance. At one million the ULP is small enough for the half-unit
law plus 1e-9 slack to stay meaningful.

-}
nonNegativeValue : Fuzzer Float
nonNegativeValue =
    Fuzz.frequency
        [ ( 1, Fuzz.constant 0 )
        , ( 1, Fuzz.constant 0.5 )
        , ( 1, Fuzz.constant 999999.999999 )
        , ( 7, Fuzz.floatRange 0 1000000 )
        ]


precision : Fuzzer Int
precision =
    Fuzz.intRange 0 6


loneCommaInput : Fuzzer String
loneCommaInput =
    Fuzz.map2
        (\before after -> before ++ "," ++ after)
        withoutDotOrComma
        withoutDotOrComma


commaInput : Fuzzer String
commaInput =
    Fuzz.oneOf
        [ withoutDotOrComma
        , Fuzz.map3
            (\first second third -> first ++ "," ++ second ++ "," ++ third)
            withoutDotOrComma
            withoutDotOrComma
            withoutDotOrComma
        ]


withoutLoneComma : Fuzzer String
withoutLoneComma =
    Fuzz.oneOf
        [ withoutDotOrComma
        , Fuzz.map3
            (\first second third -> first ++ "," ++ second ++ "," ++ third)
            withoutDotOrComma
            withoutDotOrComma
            withoutDotOrComma
        , Fuzz.map4
            (\first second third fourth ->
                first ++ "," ++ second ++ "," ++ third ++ "," ++ fourth
            )
            withoutDotOrComma
            withoutDotOrComma
            withoutDotOrComma
            withoutDotOrComma
        ]


withoutDotOrComma : Fuzzer String
withoutDotOrComma =
    Fuzz.string
        |> Fuzz.map (String.filter (\char -> char /= '.' && char /= ','))
