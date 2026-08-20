module Page.Diary.CalendarTest exposing (tests)

import Data.LogSummary exposing (DaySummary)
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Calendar as CalendarPage
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Diary.Calendar"
        [ test "loads six months ending with the current month" <|
            \_ ->
                CalendarPage.init { monthParam = Nothing, today = today }
                    |> Tuple.second
                    |> Expect.equal
                        (CalendarPage.RequestSummary
                            (date "2026-02-01")
                            today
                        )
        , test "uses a valid requested month as the return anchor" <|
            \_ ->
                CalendarPage.init
                    { monthParam = Just "2026-05"
                    , today = today
                    }
                    |> Tuple.first
                    |> .newestMonth
                    |> Expect.equal "2026-05"
        , test "selecting a day opens a calendar-aware diary route" <|
            \_ ->
                let
                    model : CalendarPage.Model
                    model =
                        CalendarPage.init
                            { monthParam = Nothing
                            , today = today
                            }
                            |> Tuple.first
                in
                CalendarPage.update
                    (CalendarPage.DayClicked "2026-07" "2026-07-20")
                    model
                    |> third
                    |> Expect.equal
                        (CalendarPage.Navigate
                            (DiaryDay
                                (Just "2026-07-20")
                                (Just "2026-07")
                            )
                        )
        , test "load earlier requests the preceding six-month block" <|
            \_ ->
                let
                    model : CalendarPage.Model
                    model =
                        CalendarPage.init
                            { monthParam = Nothing
                            , today = today
                            }
                            |> Tuple.first
                in
                CalendarPage.update CalendarPage.LoadEarlierClicked model
                    |> third
                    |> Expect.equal
                        (CalendarPage.RequestEarlierSummary
                            (date "2025-08-01")
                            (date "2026-01-31")
                        )
        , test "known totals replace that day's summary" <|
            \_ ->
                CalendarPage.update
                    (CalendarPage.DayTotalsKnown (date "2026-07-20")
                        (Just (summaryOn "2026-07-20" 750))
                    )
                    (calendarModel [ summaryOn "2026-07-20" 500 ])
                    |> first
                    |> .summaries
                    |> List.map .energyKcal
                    |> Expect.equal [ 750 ]
        , test "a day with nothing left logged loses its summary" <|
            \_ ->
                CalendarPage.update
                    (CalendarPage.DayTotalsKnown (date "2026-07-20") Nothing)
                    (calendarModel
                        [ summaryOn "2026-07-20" 500
                        , summaryOn "2026-07-21" 600
                        ]
                    )
                    |> first
                    |> .summaries
                    |> List.map .date
                    |> Expect.equal [ date "2026-07-21" ]
        , test "totals for a day outside the loaded range are ignored" <|
            \_ ->
                CalendarPage.update
                    (CalendarPage.DayTotalsKnown (date "2025-12-31")
                        (Just (summaryOn "2025-12-31" 500))
                    )
                    (calendarModel [])
                    |> first
                    |> .summaries
                    |> Expect.equal []
        , test "formats compact calorie values" <|
            \_ ->
                ( CalendarPage.compactCalories 842
                , CalendarPage.compactCalories 1312
                )
                    |> Expect.equal ( "842", "1.3k" )
        ]


summaryOn : String -> Float -> DaySummary
summaryOn raw energyKcal =
    { date = date raw
    , energyKcal = energyKcal
    , proteinG = 20
    , carbsG = 30
    , fatG = 10
    }


calendarModel : List DaySummary -> CalendarPage.Model
calendarModel summaries =
    CalendarPage.init { monthParam = Nothing, today = today }
        |> Tuple.first
        |> (\model -> { model | summaries = summaries, status = CalendarPage.Ready })


today : LocalDate
today =
    date "2026-07-29"


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            case LocalDate.fromParts 1970 1 1 of
                Just fallback ->
                    fallback

                Nothing ->
                    today


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value
