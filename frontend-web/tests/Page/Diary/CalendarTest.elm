module Page.Diary.CalendarTest exposing (tests)

import Api.Client as Client
import Data.LogSummary exposing (DaySummary)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Calendar as Calendar
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Calendar"
        [ test "a user loads the calendar and opens a day" <|
            \_ ->
                loadedCalendar
                    |> step (Calendar.DayClicked "2026-07" (Fixtures.date "2026-07-20"))
                    |> finish
                        (\( model, outMsg ) ->
                            { screen = toScreen model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { screen = loadedScreen
                                    , finalOut =
                                        Calendar.Navigate
                                            (DiaryDay
                                                (Just (Fixtures.date "2026-07-20"))
                                                (Just "2026-07")
                                            )
                                    }
                        )
        , test "a user loads an older range" <|
            \_ ->
                loadedCalendar
                    |> step Calendar.LoadEarlierClicked
                    |> step
                        (Calendar.EarlierSummaryLoaded 1
                            (Ok [ summary "2026-01-15" 300 ])
                        )
                    |> finish
                        (\( model, outMsg ) ->
                            { screen = toScreen model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { screen =
                                        { labels =
                                            [ ( "2026-01-15", "300" )
                                            , ( "2026-07-20", "500" )
                                            , ( "2026-07-21", "1.3k" )
                                            ]
                                        , range = ( "2025-08", "2026-07" )
                                        , earlier = Just loadEarlierLabel
                                        , error = Nothing
                                        }
                                    , finalOut = Calendar.NoOp
                                    }
                        )
        , test "a failed load can be retried" <|
            \_ ->
                Calendar.init { monthParam = Nothing, today = today }
                    |> Story.start
                    |> step (Calendar.SummaryLoaded 0 (Err Client.NetworkError))
                    |> step Calendar.RetryClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (Calendar.RequestSummary
                                        1
                                        (Fixtures.date "2026-02-01")
                                        (Fixtures.date "2026-07-29")
                                    )
                        )
        ]


type alias Screen =
    { labels : List ( String, String )
    , range : ( String, String )
    , earlier : Maybe String
    , error : Maybe String
    }


toScreen : Calendar.Model -> Screen
toScreen model =
    { labels =
        model.summaries
            |> List.map
                (\day ->
                    ( LocalDate.format day.date
                    , Calendar.compactCalories day.energyKcal
                    )
                )
    , range = ( model.oldestMonth, model.newestMonth )
    , earlier =
        case model.status of
            Calendar.Ready ->
                Just loadEarlierLabel

            Calendar.LoadingEarlier ->
                Just loadingLabel

            _ ->
                Nothing
    , error =
        case model.status of
            Calendar.Failed message ->
                Just message

            _ ->
                Nothing
    }


loadedScreen : Screen
loadedScreen =
    { labels = [ ( "2026-07-20", "500" ), ( "2026-07-21", "1.3k" ) ]
    , range = ( "2026-02", "2026-07" )
    , earlier = Just loadEarlierLabel
    , error = Nothing
    }


summary : String -> Float -> DaySummary
summary raw energyKcal =
    { date = Fixtures.date raw
    , energyKcal = energyKcal
    , proteinG = 0
    , carbsG = 0
    , fatG = 0
    }


today : LocalDate
today =
    Fixtures.date "2026-07-29"


loadEarlierLabel : String
loadEarlierLabel =
    I18n.en TidDiaryCalendarLoadEarlier


loadingLabel : String
loadingLabel =
    I18n.en TidCommonLoading



-- STORY PIPELINE


type alias Journey =
    Story.Journey Calendar.Model Calendar.OutMsg


step : Calendar.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd Calendar.update)


finish :
    (( Calendar.Model, Calendar.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedCalendar : Journey
loadedCalendar =
    Calendar.init { monthParam = Nothing, today = today }
        |> Story.start
        |> step
            (Calendar.SummaryLoaded 0
                (Ok
                    [ summary "2026-07-20" 500
                    , summary "2026-07-21" 1312
                    ]
                )
            )
