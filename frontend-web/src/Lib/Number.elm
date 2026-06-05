module Lib.Number exposing (toFixed, toFixedOne, toFixedTrimmed)


toFixedOne : Float -> String
toFixedOne value =
    toFixed 1 value


toFixed : Int -> Float -> String
toFixed precision value =
    let
        factor : Int
        factor =
            powerOfTen precision

        scaled : Int
        scaled =
            round (value * toFloat factor)

        whole : Int
        whole =
            scaled // factor

        fractional : Int
        fractional =
            abs (modBy factor scaled)
    in
    if precision <= 0 then
        String.fromInt scaled

    else
        String.fromInt whole
            ++ "."
            ++ String.padLeft precision '0' (String.fromInt fractional)


toFixedTrimmed : Int -> Float -> String
toFixedTrimmed precision value =
    if precision <= 0 then
        toFixed precision value

    else
        let
            formatted : String
            formatted =
                toFixed precision value

            trimmed : String
            trimmed =
                stripTrailing '0' formatted
        in
        stripTrailing '.' trimmed


powerOfTen : Int -> Int
powerOfTen precision =
    if precision <= 0 then
        1

    else
        10 * powerOfTen (precision - 1)


stripTrailing : Char -> String -> String
stripTrailing c s =
    if String.endsWith (String.fromChar c) s then
        stripTrailing c (String.dropRight 1 s)

    else
        s
