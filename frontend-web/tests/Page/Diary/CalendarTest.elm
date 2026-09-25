module Page.Diary.CalendarTest exposing (tests)

import Api.Client as Client
import Data.LogSummary exposing (DaySummary)
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Calendar as CalendarPage
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Diary.Calendar"
        [ test "opening the calendar requests the last six months and renders the loaded days" <|
            \_ ->
                let
                    ( loading, initialOut ) =
                        CalendarPage.init { monthParam = Nothing, today = today }

                    loadedModel : CalendarPage.Model
                    loadedModel =
                        step (CalendarPage.SummaryLoaded 0 (Ok [ summaryOn "2026-07-20" 500 ]))
                            loading
                in
                { request = initialOut
                , compact = ( CalendarPage.compactCalories 842, CalendarPage.compactCalories 1312 )
                , screen = toScreen loadedModel
                }
                    |> Expect.equal
                        { request =
                            CalendarPage.RequestSummary
                                0
                                (date "2026-02-01")
                                today
                        , compact = ( "842", "1.3k" )
                        , screen =
                            { status = "ready"
                            , days = [ ( "2026-07-20", 500 ) ]
                            , oldestMonth = "2026-02"
                            , newestMonth = "2026-07"
                            }
                        }
        , test "loading earlier appends an older block and is blocked while a load is in flight" <|
            \_ ->
                let
                    earlier : CalendarPage.Model
                    earlier =
                        step CalendarPage.LoadEarlierClicked (loaded [ summaryOn "2026-07-20" 500 ])

                    duringLoad : CalendarPage.OutMsg
                    duringLoad =
                        out CalendarPage.LoadEarlierClicked earlier

                    composed : CalendarPage.Model
                    composed =
                        step
                            (CalendarPage.EarlierSummaryLoaded
                                1
                                (Ok [ summaryOn "2026-01-15" 300 ])
                            )
                            earlier
                in
                { request = out CalendarPage.LoadEarlierClicked (loaded [])
                , loadingEarlier = toScreen earlier
                , blocked = duringLoad
                , composed = toScreen composed
                }
                    |> Expect.equal
                        { request =
                            CalendarPage.RequestEarlierSummary
                                1
                                (date "2025-08-01")
                                (date "2026-01-31")
                        , loadingEarlier =
                            { status = "loadingEarlier"
                            , days = [ ( "2026-07-20", 500 ) ]
                            , oldestMonth = "2025-08"
                            , newestMonth = "2026-07"
                            }
                        , blocked = CalendarPage.NoOp
                        , composed =
                            { status = "ready"
                            , days = [ ( "2026-01-15", 300 ), ( "2026-07-20", 500 ) ]
                            , oldestMonth = "2025-08"
                            , newestMonth = "2026-07"
                            }
                        }
        , test "selecting a day opens a calendar-aware diary route" <|
            \_ ->
                out (CalendarPage.DayClicked "2026-07" "2026-07-20") (loaded [])
                    |> Expect.equal
                        (CalendarPage.Navigate
                            (DiaryDay (Just "2026-07-20") (Just "2026-07"))
                        )
        , test "day totals replace or clear loaded days and ignore days still in the future" <|
            \_ ->
                let
                    edited : CalendarPage.Model
                    edited =
                        loaded [ summaryOn "2026-07-20" 500, summaryOn "2026-07-21" 600 ]
                            |> step
                                (CalendarPage.DayTotalsKnown
                                    (date "2026-07-20")
                                    (Just (summaryOn "2026-07-20" 700))
                                )
                            |> step (CalendarPage.DayTotalsKnown (date "2026-07-21") Nothing)
                            |> step
                                (CalendarPage.DayTotalsKnown
                                    (date "2026-07-30")
                                    (Just (summaryOn "2026-07-30" 500))
                                )

                    afterRollover : CalendarPage.Model
                    afterRollover =
                        edited
                            |> step (CalendarPage.TodayChanged (date "2026-07-30"))
                            |> step
                                (CalendarPage.DayTotalsKnown
                                    (date "2026-07-30")
                                    (Just (summaryOn "2026-07-30" 500))
                                )
                in
                { beforeRollover = toScreen edited
                , afterRollover = toScreen afterRollover
                }
                    |> Expect.equal
                        { beforeRollover =
                            { status = "ready"
                            , days = [ ( "2026-07-20", 700 ) ]
                            , oldestMonth = "2026-02"
                            , newestMonth = "2026-07"
                            }
                        , afterRollover =
                            { status = "ready"
                            , days = [ ( "2026-07-20", 700 ), ( "2026-07-30", 500 ) ]
                            , oldestMonth = "2026-02"
                            , newestMonth = "2026-07"
                            }
                        }
        , test "a stale summary response is ignored" <|
            \_ ->
                loaded [ summaryOn "2026-07-20" 500 ]
                    |> step
                        (CalendarPage.SummaryLoaded 99 (Ok [ summaryOn "2026-07-25" 900 ]))
                    |> toScreen
                    |> .days
                    |> Expect.equal [ ( "2026-07-20", 500 ) ]
        , test "a failed earlier load keeps the calendar already on screen" <|
            \_ ->
                loaded [ summaryOn "2026-07-20" 500 ]
                    |> step CalendarPage.LoadEarlierClicked
                    |> step (CalendarPage.EarlierSummaryLoaded 1 (Err Client.NetworkError))
                    |> toScreen
                    |> Expect.equal
                        { status = "ready"
                        , days = [ ( "2026-07-20", 500 ) ]
                        , oldestMonth = "2026-02"
                        , newestMonth = "2026-07"
                        }
        , test "an unauthorized summary load expires the session" <|
            \_ ->
                out
                    (CalendarPage.SummaryLoaded
                        0
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    (loaded [])
                    |> Expect.equal CalendarPage.SessionExpired
        ]



-- SCREEN PROJECTION


type alias Screen =
    { status : String
    , days : List ( String, Float )
    , oldestMonth : String
    , newestMonth : String
    }


toScreen : CalendarPage.Model -> Screen
toScreen model =
    { status =
        case model.status of
            CalendarPage.Loading ->
                "loading"

            CalendarPage.Ready ->
                "ready"

            CalendarPage.LoadingEarlier ->
                "loadingEarlier"

            CalendarPage.Failed _ ->
                "failed"
    , days =
        model.summaries
            |> List.map (\summary -> ( LocalDate.format summary.date, summary.energyKcal ))
    , oldestMonth = model.oldestMonth
    , newestMonth = model.newestMonth
    }


loaded : List DaySummary -> CalendarPage.Model
loaded summaries =
    CalendarPage.init { monthParam = Nothing, today = today }
        |> Tuple.first
        |> step (CalendarPage.SummaryLoaded 0 (Ok summaries))


summaryOn : String -> Float -> DaySummary
summaryOn raw energyKcal =
    { date = date raw
    , energyKcal = energyKcal
    , proteinG = 20
    , carbsG = 30
    , fatG = 10
    }


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


step : CalendarPage.Msg -> CalendarPage.Model -> CalendarPage.Model
step msg model =
    first (CalendarPage.update msg model)


out : CalendarPage.Msg -> CalendarPage.Model -> CalendarPage.OutMsg
out msg model =
    third (CalendarPage.update msg model)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
