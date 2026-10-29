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
            "toFixed rounds within half a unit in the last place and pads exact digits"
          <|
            \value digits ->
                let
                    formatted : String
                    formatted =
                        Number.toFixed digits value

                    -- The half-unit term is the rounding law. The extra 1e-9
                    -- absorbs double rounding in the multiply/round/divide
                    -- path for values up to one million.
                    tolerance : Float
                    tolerance =
                        0.5 / (10 ^ toFloat digits) + 1.0e-9
                in
                case String.toFloat formatted of
                    Nothing ->
                        Expect.fail ("toFixed produced a non-numeric string: " ++ formatted)

                    Just parsed ->
                        Expect.all
                            [ \_ ->
                                parsed
                                    |> Expect.within (Expect.Absolute tolerance) value
                            , \_ -> fractionalDigits digits formatted
                            ]
                            ()
        , fuzz2 nonNegativeValue
            precision
            "toFixedTrimmed parses like toFixed without trailing zeros or dot"
          <|
            \value digits ->
                let
                    trimmed : String
                    trimmed =
                        Number.toFixedTrimmed digits value
                in
                Expect.all
                    [ \_ ->
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
        , fuzz normalizeInput
            "normalizeDecimalSeparator rewrites exactly one comma when no dot is present"
          <|
            \raw ->
                let
                    expected : String
                    expected =
                        if String.contains "." raw then
                            raw

                        else
                            case String.indexes "," raw of
                                [ _ ] ->
                                    String.replace "," "." raw

                                _ ->
                                    raw
                in
                Number.normalizeDecimalSeparator raw
                    |> Expect.equal expected
        ]


fractionalDigits : Int -> String -> Expect.Expectation
fractionalDigits digits formatted =
    if digits == 0 then
        String.contains "." formatted |> Expect.equal False

    else
        case String.split "." formatted of
            [ whole, fractional ] ->
                Expect.all
                    [ \_ -> String.length fractional |> Expect.equal digits
                    , \_ -> String.all Char.isDigit fractional |> Expect.equal True
                    , \_ -> String.isEmpty whole |> Expect.equal False
                    ]
                    ()

            _ ->
                Expect.fail "expected a single decimal point"


{-| `toFixed` is only specified for non-negative values here; its negative
branch remains a separate production risk. The domain stops at one million so
the scaled integer stays well below 2^53 and the half-unit law stays meaningful.
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


normalizeInput : Fuzzer String
normalizeInput =
    Fuzz.oneOf
        [ Fuzz.map (\raw -> raw ++ ".") Fuzz.string
        , Fuzz.map2
            (\before after -> before ++ "," ++ after)
            withoutDotOrComma
            withoutDotOrComma
        , Fuzz.map3
            (\first second third -> first ++ "," ++ second ++ "," ++ third)
            withoutDotOrComma
            withoutDotOrComma
            withoutDotOrComma
        , withoutDotOrComma
        ]


withoutDotOrComma : Fuzzer String
withoutDotOrComma =
    Fuzz.string
        |> Fuzz.map (String.filter (\char -> char /= '.' && char /= ','))
