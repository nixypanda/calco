module Data.Calendar exposing
    ( dayKey
    , monthCells
    , monthEnd
    , monthKey
    , monthLabel
    , monthStart
    , monthsDescending
    , shiftMonth
    )

import Lib.Date as LocalDate exposing (LocalDate)


monthKey : LocalDate -> String
monthKey date =
    String.left 7 (LocalDate.format date)


shiftMonth : Int -> String -> String
shiftMonth offset period =
    case parseMonth period of
        Just ( year, month ) ->
            let
                zeroBased : Int
                zeroBased =
                    year * 12 + month - 1 + offset

                nextYear : Int
                nextYear =
                    floor (toFloat zeroBased / 12)

                nextMonth : Int
                nextMonth =
                    modBy 12 zeroBased + 1
            in
            monthPeriod nextYear nextMonth

        Nothing ->
            period


monthsDescending : Int -> String -> List String
monthsDescending count first =
    List.range 0 (max 0 (count - 1))
        |> List.map (\offset -> shiftMonth -offset first)


monthCells : String -> List (Maybe Int)
monthCells period =
    case parseMonth period of
        Just ( year, month ) ->
            let
                cells : List (Maybe Int)
                cells =
                    List.repeat (dayOfWeek year month 1) Nothing
                        ++ List.map Just (List.range 1 (daysInMonth year month))

                trailing : Int
                trailing =
                    modBy 7 (7 - modBy 7 (List.length cells))
            in
            cells ++ List.repeat trailing Nothing

        Nothing ->
            []


monthStart : String -> Maybe LocalDate
monthStart period =
    parseMonth period
        |> Maybe.andThen (\( year, month ) -> LocalDate.fromParts year month 1)


monthEnd : String -> Maybe LocalDate
monthEnd period =
    parseMonth period
        |> Maybe.andThen
            (\( year, month ) ->
                LocalDate.fromParts year month (daysInMonth year month)
            )


dayKey : String -> Int -> String
dayKey period day =
    period ++ "-" ++ String.padLeft 2 '0' (String.fromInt day)


monthLabel : String -> String
monthLabel period =
    case parseMonth period of
        Just ( year, month ) ->
            monthName month ++ " " ++ String.fromInt year

        Nothing ->
            period


parseMonth : String -> Maybe ( Int, Int )
parseMonth period =
    case String.split "-" period of
        [ yearText, monthText ] ->
            Maybe.map2 Tuple.pair
                (String.toInt yearText)
                (String.toInt monthText)
                |> Maybe.andThen
                    (\( year, month ) ->
                        if String.length yearText == 4 && month >= 1 && month <= 12 then
                            Just ( year, month )

                        else
                            Nothing
                    )

        _ ->
            Nothing


monthPeriod : Int -> Int -> String
monthPeriod year month =
    String.fromInt year ++ "-" ++ String.padLeft 2 '0' (String.fromInt month)


daysInMonth : Int -> Int -> Int
daysInMonth year month =
    case month of
        2 ->
            if modBy 400 year == 0 || (modBy 4 year == 0 && modBy 100 year /= 0) then
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


dayOfWeek : Int -> Int -> Int -> Int
dayOfWeek year month day =
    let
        adjustedYear : Int
        adjustedYear =
            if month < 3 then
                year - 1

            else
                year

        adjustedMonth : Int
        adjustedMonth =
            if month < 3 then
                month + 12

            else
                month

        zeroSunday : Int
        zeroSunday =
            day
                + floor (toFloat (13 * (adjustedMonth + 1)) / 5)
                + adjustedYear
                + floor (toFloat adjustedYear / 4)
                - floor (toFloat adjustedYear / 100)
                + floor (toFloat adjustedYear / 400)
    in
    modBy 7 (zeroSunday + 6)


monthName : Int -> String
monthName month =
    case month of
        1 ->
            "January"

        2 ->
            "February"

        3 ->
            "March"

        4 ->
            "April"

        5 ->
            "May"

        6 ->
            "June"

        7 ->
            "July"

        8 ->
            "August"

        9 ->
            "September"

        10 ->
            "October"

        11 ->
            "November"

        12 ->
            "December"

        _ ->
            ""
