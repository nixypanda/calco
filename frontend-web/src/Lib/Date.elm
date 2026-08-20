module Lib.Date exposing
    ( LocalDate
    , addDays
    , clampTo
    , compare
    , decoder
    , display
    , equals
    , format
    , fromParts
    , fromPosix
    , fromString
    , nextOnOrBefore
    )

import Char
import Json.Decode as Decode exposing (Decoder)
import Time


type LocalDate
    = LocalDate { year : Int, month : Int, day : Int }


fromString : String -> Maybe LocalDate
fromString raw =
    let
        parts : List String
        parts =
            String.split "-" raw
    in
    case parts of
        [ year, month, day ] ->
            Maybe.map3 fromParts
                (parseFixedInt 4 year)
                (parseFixedInt 2 month)
                (parseFixedInt 2 day)
                |> Maybe.andThen identity

        _ ->
            Nothing


decoder : Decoder LocalDate
decoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case fromString raw of
                    Just date ->
                        Decode.succeed date

                    Nothing ->
                        Decode.fail ("Invalid local date: " ++ raw)
            )


fromParts : Int -> Int -> Int -> Maybe LocalDate
fromParts year month day =
    if month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth year month then
        Just (LocalDate { year = year, month = month, day = day })

    else
        Nothing


fromPosix : Time.Zone -> Time.Posix -> LocalDate
fromPosix zone posix =
    LocalDate
        { year = Time.toYear zone posix
        , month = Time.toMonth zone posix |> monthToInt
        , day = Time.toDay zone posix
        }


format : LocalDate -> String
format (LocalDate date) =
    pad4 date.year ++ "-" ++ pad2 date.month ++ "-" ++ pad2 date.day


display : LocalDate -> String
display (LocalDate date) =
    monthName date.month ++ " " ++ String.fromInt date.day ++ ", " ++ String.fromInt date.year


addDays : Int -> LocalDate -> LocalDate
addDays offset date =
    if offset == 0 then
        date

    else if offset > 0 then
        addDays (offset - 1) (nextDay date)

    else
        addDays (offset + 1) (previousDay date)


compare : LocalDate -> LocalDate -> Order
compare (LocalDate left) (LocalDate right) =
    Basics.compare ( left.year, left.month, left.day ) ( right.year, right.month, right.day )


equals : LocalDate -> LocalDate -> Bool
equals left right =
    compare left right == EQ


clampTo : LocalDate -> LocalDate -> LocalDate
clampTo maximum date =
    case compare date maximum of
        GT ->
            maximum

        _ ->
            date


nextOnOrBefore : LocalDate -> LocalDate -> Maybe LocalDate
nextOnOrBefore today current =
    let
        next : LocalDate
        next =
            addDays 1 current
    in
    case compare next today of
        GT ->
            Nothing

        _ ->
            Just next


nextDay : LocalDate -> LocalDate
nextDay (LocalDate date) =
    if date.day < daysInMonth date.year date.month then
        LocalDate { date | day = date.day + 1 }

    else if date.month < 12 then
        LocalDate { date | month = date.month + 1, day = 1 }

    else
        LocalDate { year = date.year + 1, month = 1, day = 1 }


previousDay : LocalDate -> LocalDate
previousDay (LocalDate date) =
    if date.day > 1 then
        LocalDate { date | day = date.day - 1 }

    else if date.month > 1 then
        LocalDate { date | month = date.month - 1, day = daysInMonth date.year (date.month - 1) }

    else
        LocalDate { year = date.year - 1, month = 12, day = 31 }


parseFixedInt : Int -> String -> Maybe Int
parseFixedInt expectedLength raw =
    if String.length raw == expectedLength && String.all Char.isDigit raw then
        String.toInt raw

    else
        Nothing


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value


pad4 : Int -> String
pad4 value =
    let
        raw : String
        raw =
            String.fromInt value
    in
    String.repeat (max 0 (4 - String.length raw)) "0" ++ raw


daysInMonth : Int -> Int -> Int
daysInMonth year month =
    case month of
        2 ->
            if isLeapYear year then
                29

            else
                28

        4 ->
            30

        6 ->
            30

        9 ->
            30

        11 ->
            30

        _ ->
            31


isLeapYear : Int -> Bool
isLeapYear year =
    modBy 400 year == 0 || (modBy 4 year == 0 && modBy 100 year /= 0)


monthToInt : Time.Month -> Int
monthToInt month =
    case month of
        Time.Jan ->
            1

        Time.Feb ->
            2

        Time.Mar ->
            3

        Time.Apr ->
            4

        Time.May ->
            5

        Time.Jun ->
            6

        Time.Jul ->
            7

        Time.Aug ->
            8

        Time.Sep ->
            9

        Time.Oct ->
            10

        Time.Nov ->
            11

        Time.Dec ->
            12


monthName : Int -> String
monthName month =
    case month of
        1 ->
            "Jan"

        2 ->
            "Feb"

        3 ->
            "Mar"

        4 ->
            "Apr"

        5 ->
            "May"

        6 ->
            "Jun"

        7 ->
            "Jul"

        8 ->
            "Aug"

        9 ->
            "Sep"

        10 ->
            "Oct"

        11 ->
            "Nov"

        12 ->
            "Dec"

        _ ->
            ""
