module Page.Diary.CalendarTest exposing (tests)

{-| Calendar stories.

The first story retries a failed initial summary and composes an older range.
The second covers day selection, stale summaries, failed earlier loads, and the
page-level 401 check. Load tokens only address simulated completions.

-}

import Api.Client as Client
import Data.LogSummary exposing (DaySummary)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Calendar as Calendar
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Calendar"
        [ test "a failed first load retries, then an older range is composed" <|
            \_ ->
                let
                    ( initial, initialOut ) =
                        Calendar.init { monthParam = Nothing, today = today }

                    failed : Calendar.Model
                    failed =
                        step (Calendar.SummaryLoaded 0 (Err Client.NetworkError)) initial

                    ( retrying, retryOut ) =
                        stepOnce Calendar.RetryClicked failed

                    loaded : Calendar.Model
                    loaded =
                        step
                            (Calendar.SummaryLoaded 1
                                (Ok
                                    [ summary "2026-07-20" 500
                                    , summary "2026-07-21" 1312
                                    ]
                                )
                            )
                            retrying

                    ( loadingEarlier, earlierOut ) =
                        stepOnce Calendar.LoadEarlierClicked loaded

                    ( afterStale, staleOut ) =
                        stepOnce
                            (Calendar.EarlierSummaryLoaded 1 (Ok [ summary "2026-07-25" 900 ]))
                            loadingEarlier

                    ( composed, composedOut ) =
                        stepOnce
                            (Calendar.EarlierSummaryLoaded 2 (Ok [ summary "2026-01-15" 300 ]))
                            afterStale
                in
                { initialRequest = request initialOut
                , failure = ( .error <| toScreen failed, .earlier <| toScreen failed )
                , retryRequest = request retryOut
                , loaded = toScreen loaded
                , earlierRequest = request earlierOut
                , loadingEarlier =
                    ( .earlier <| toScreen loadingEarlier
                    , .range <| toScreen loadingEarlier
                    )
                , staleOut = staleOut
                , staleUnchanged = toScreen afterStale == toScreen loadingEarlier
                , composedOut = composedOut
                , composed = ( .labels <| toScreen composed, .range <| toScreen composed )
                }
                    |> Expect.equal
                        { initialRequest = Just ( "summary", "2026-02-01", "2026-07-29" )
                        , failure = ( Just Fixtures.networkErrorMessage, Nothing )
                        , retryRequest = Just ( "summary", "2026-02-01", "2026-07-29" )
                        , loaded = loadedScreen
                        , earlierRequest = Just ( "earlier", "2025-08-01", "2026-01-31" )
                        , loadingEarlier = ( Just loadingLabel, ( "2025-08", "2026-07" ) )
                        , staleOut = Calendar.NoOp
                        , staleUnchanged = True
                        , composedOut = Calendar.NoOp
                        , composed =
                            ( [ ( "2026-01-15", "300" )
                              , ( "2026-07-20", "500" )
                              , ( "2026-07-21", "1.3k" )
                              ]
                            , ( "2025-08", "2026-07" )
                            )
                        }
        , test "selecting a day navigates; stale and failed earlier loads keep the calendar" <|
            \_ ->
                let
                    loaded : Calendar.Model
                    loaded =
                        Calendar.init { monthParam = Nothing, today = today }
                            |> Tuple.first
                            |> step
                                (Calendar.SummaryLoaded 0
                                    (Ok [ summary "2026-07-20" 500, summary "2026-07-21" 1312 ])
                                )

                    ( _, dayOut ) =
                        stepOnce
                            (Calendar.DayClicked "2026-07" (Fixtures.date "2026-07-20"))
                            loaded

                    ( afterStale, staleOut ) =
                        stepOnce
                            (Calendar.SummaryLoaded 99 (Ok [ summary "2026-07-25" 900 ]))
                            loaded

                    ( loadingEarlier, earlierOut ) =
                        stepOnce Calendar.LoadEarlierClicked afterStale

                    ( failedEarlier, failedEarlierOut ) =
                        stepOnce
                            (Calendar.EarlierSummaryLoaded 1 (Err Client.NetworkError))
                            loadingEarlier

                    ( retrying, retryOut ) =
                        stepOnce Calendar.LoadEarlierClicked failedEarlier

                    finalOut : Calendar.OutMsg
                    finalOut =
                        stepOnce
                            (Calendar.EarlierSummaryLoaded 2 (Err Fixtures.unauthorized))
                            retrying
                            |> Tuple.second
                in
                { loaded = loadedScreen
                , dayOut = dayOut
                , staleOut = staleOut
                , staleUnchanged = toScreen afterStale == loadedScreen
                , earlierRequest = request earlierOut
                , failedEarlierOut = failedEarlierOut
                , failedEarlier = toScreen failedEarlier
                , retryRequest = request retryOut
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { loaded = loadedScreen
                        , dayOut =
                            Calendar.Navigate
                                (DiaryDay (Just (Fixtures.date "2026-07-20")) (Just "2026-07"))
                        , staleOut = Calendar.NoOp
                        , staleUnchanged = True
                        , earlierRequest = Just ( "earlier", "2025-08-01", "2026-01-31" )
                        , failedEarlierOut = Calendar.NoOp
                        , failedEarlier = loadedScreen
                        , retryRequest = Just ( "earlier", "2025-08-01", "2026-01-31" )
                        , finalOut = Calendar.SessionExpired
                        }
        ]



-- SCREEN PROJECTION


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



-- HELPERS


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


step : Calendar.Msg -> Calendar.Model -> Calendar.Model
step msg model =
    Tuple.first (stepOnce msg model)


stepOnce : Calendar.Msg -> Calendar.Model -> ( Calendar.Model, Calendar.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            Calendar.update msg model
    in
    ( next, outMsg )


request : Calendar.OutMsg -> Maybe ( String, String, String )
request outMsg =
    case outMsg of
        Calendar.RequestSummary _ from to ->
            Just ( "summary", LocalDate.format from, LocalDate.format to )

        Calendar.RequestEarlierSummary _ from to ->
            Just ( "earlier", LocalDate.format from, LocalDate.format to )

        _ ->
            Nothing
