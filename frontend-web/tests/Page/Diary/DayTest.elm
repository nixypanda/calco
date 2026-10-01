module Page.Diary.DayTest exposing (tests)

import Api.Client as Client
import Api.Logs
import Data.FoodLog as FoodLog exposing (FoodLog, LogItem)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.ItemRef as ItemRef
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (NutrientAmount, Quantity)
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Day as DiaryDay
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.Diary.Day"
        [ describe "date navigation"
            [ test "paging to a neighbouring day keeps the calendar context and stops at today" <|
                \_ ->
                    let
                        withCalendar : LocalDate -> DiaryDay.Model
                        withCalendar currentDate =
                            DiaryDay.init
                                { date = currentDate
                                , calendarMonth = Just "2026-05"
                                , today = today
                                }
                                |> Tuple.first
                    in
                    { previous = out DiaryDay.PreviousDayClicked (withCalendar today)
                    , next = out DiaryDay.NextDayClicked (withCalendar yesterday)
                    , atToday = out DiaryDay.NextDayClicked (initModel today)
                    }
                        |> Expect.equal
                            { previous =
                                DiaryDay.Navigate
                                    (DiaryDay (Just "2026-05-29") (Just "2026-05"))
                            , next =
                                DiaryDay.Navigate
                                    (DiaryDay (Just "2026-05-30") (Just "2026-05"))
                            , atToday = DiaryDay.NoOp
                            }
            , test "a day that rolls over becomes the next navigable day" <|
                \_ ->
                    initModel today
                        |> step (DiaryDay.TodayChanged tomorrow)
                        |> out DiaryDay.NextDayClicked
                        |> Expect.equal
                            (DiaryDay.Navigate (DiaryDay (Just "2026-05-31") Nothing))
            , test "diary actions navigate with the selected day and calendar context" <|
                \_ ->
                    { details = out DiaryDay.DetailsClicked (initModel yesterday)
                    , addFood = out (DiaryDay.AddFoodClicked Lunch) (initModel today)
                    , log = out (DiaryDay.LogClicked "log-1") (initModel today)
                    , meals = out DiaryDay.MealsClicked (initModel today)
                    }
                        |> Expect.equal
                            { details =
                                DiaryDay.Navigate (NutritionDetails (Just "2026-05-29"))
                            , addFood =
                                DiaryDay.Navigate
                                    (FoodSearch (Just "2026-05-30") (Just Lunch))
                            , log =
                                DiaryDay.Navigate
                                    (FoodLogEntry "log-1" (Just "2026-05-30") Nothing)
                            , meals = DiaryDay.Navigate MealList
                            }
            ]
        , describe "loading"
            [ test "the diary loads only after logs and goal arrive and filters by date" <|
                \_ ->
                    let
                        logsOnly : DiaryDay.Model
                        logsOnly =
                            step
                                (DiaryDay.LogsLoaded today (Ok [ lunchLog, yesterdayLunchLog ]))
                                (initModel today)

                        goalOnly : DiaryDay.Model
                        goalOnly =
                            step
                                (DiaryDay.GoalLoaded today (Ok goalSnapshot))
                                (initModel today)

                        completeByGoal : DiaryDay.Model
                        completeByGoal =
                            step
                                (DiaryDay.LogsLoaded today (Ok [ lunchLog, yesterdayLunchLog ]))
                                goalOnly

                        completeByLogs : DiaryDay.Model
                        completeByLogs =
                            step
                                (DiaryDay.GoalLoaded today (Ok goalSnapshot))
                                logsOnly
                    in
                    { request =
                        DiaryDay.init
                            { date = today, calendarMonth = Nothing, today = today }
                            |> Tuple.second
                    , logsOnly = toScreen logsOnly
                    , goalOnly = toScreen goalOnly
                    , completeByGoal = toScreen completeByGoal
                    , completeByLogs = toScreen completeByLogs
                    }
                        |> Expect.equal
                            { request = DiaryDay.RequestDiaryData
                            , logsOnly =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = [ "log-1" ]
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , goalOnly =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = []
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , completeByGoal =
                                { phase = "loaded"
                                , date = "2026-05-30"
                                , logs = [ "log-1" ]
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , completeByLogs =
                                { phase = "loaded"
                                , date = "2026-05-30"
                                , logs = [ "log-1" ]
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            }
            , test "log and goal responses for another day are ignored" <|
                \_ ->
                    let
                        seeded : DiaryDay.Model
                        seeded =
                            initModel today
                                |> step
                                    (DiaryDay.LogsLoaded today (Ok [ breakfastLog ]))
                                |> step (DiaryDay.GoalLoaded today (Ok goalSnapshot))

                        afterStaleLogs : DiaryDay.Model
                        afterStaleLogs =
                            step
                                (DiaryDay.LogsLoaded yesterday (Err Client.NetworkError))
                                seeded

                        afterStaleGoal : DiaryDay.Model
                        afterStaleGoal =
                            step
                                (DiaryDay.GoalLoaded yesterday (Ok staleGoalSnapshot))
                                seeded
                    in
                    { seeded = toScreen seeded
                    , staleLogs = toScreen afterStaleLogs
                    , staleGoal = toScreen afterStaleGoal
                    }
                        |> Expect.equal
                            { seeded = loadedScreen [ "log-3" ]
                            , staleLogs = loadedScreen [ "log-3" ]
                            , staleGoal = loadedScreen [ "log-3" ]
                            }
            , test "a diary load failure is shown and an unauthorized load expires the session" <|
                \_ ->
                    { failed =
                        step
                            (DiaryDay.LogsLoaded today (Err Client.NetworkError))
                            (initModel today)
                            |> toScreen
                            |> .error
                    , unauthorized =
                        out
                            (DiaryDay.GoalLoaded
                                today
                                (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                            )
                            (initModel today)
                    }
                        |> Expect.equal
                            { failed = Just networkErrorMessage
                            , unauthorized = DiaryDay.SessionExpired
                            }
            ]
        , describe "latest slots"
            [ test "known slots are kept and unknown slots are dropped" <|
                \_ ->
                    initModel today
                        |> step
                            (DiaryDay.LatestSlotsReceived today
                                (Ok
                                    { slots =
                                        [ { dinnerSlotResponse | mealSlot = Nothing }
                                        , lunchSlotResponse
                                        ]
                                    }
                                )
                            )
                        |> toScreen
                        |> Expect.equal
                            { phase = "loading"
                            , date = "2026-05-30"
                            , logs = []
                            , error = Nothing
                            , copy = "idle"
                            , slotState = "loaded"
                            , suggestions = [ "lunch" ]
                            }
            , test "a transport failure degrades to no suggestions and 401 expires" <|
                \_ ->
                    { transport =
                        step
                            (DiaryDay.LatestSlotsReceived today (Err Client.NetworkError))
                            (initModel today)
                            |> toScreen
                    , unauthorized =
                        out
                            (DiaryDay.LatestSlotsReceived
                                today
                                (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                            )
                            (initModel today)
                    }
                        |> Expect.equal
                            { transport =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = []
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "failed"
                                , suggestions = []
                                }
                            , unauthorized = DiaryDay.SessionExpired
                            }
            , test "a stale latest-slots response is ignored" <|
                \_ ->
                    let
                        seeded : DiaryDay.Model
                        seeded =
                            initModel today
                                |> step
                                    (DiaryDay.LatestSlotsReceived today
                                        (Ok { slots = [ dinnerSlotResponse ] })
                                    )

                        afterStale : DiaryDay.Model
                        afterStale =
                            step
                                (DiaryDay.LatestSlotsReceived yesterday
                                    (Ok { slots = [ lunchSlotResponse ] })
                                )
                                seeded
                    in
                    { seeded = toScreen seeded |> .suggestions
                    , stale = toScreen afterStale |> .suggestions
                    }
                        |> Expect.equal
                            { seeded = [ "dinner" ]
                            , stale = [ "dinner" ]
                            }
            ]
        , describe "repeat logging"
            [ test "logging the latest dinner appends its logs and retires the suggestion" <|
                \_ ->
                    let
                        seeded : DiaryDay.Model
                        seeded =
                            initModel today
                                |> step
                                    (DiaryDay.LatestSlotsReceived today
                                        (Ok
                                            { slots =
                                                [ dinnerSlotResponse, lunchSlotResponse ]
                                            }
                                        )
                                    )
                                |> step (DiaryDay.LogsLoaded today (Ok [ breakfastLog ]))
                                |> step (DiaryDay.GoalLoaded today (Ok goalSnapshot))

                        copying : DiaryDay.Model
                        copying =
                            step (DiaryDay.CopyLatestClicked dinnerSource) seeded

                        completed : DiaryDay.Model
                        completed =
                            step
                                (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                                copying
                    in
                    { request = out (DiaryDay.CopyLatestClicked dinnerSource) seeded
                    , copying = toScreen copying
                    , completed = toScreen completed
                    , completedOut =
                        out
                            (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                            copying
                    }
                        |> Expect.equal
                            { request =
                                DiaryDay.RequestCopyLatestSlot today
                                    [ { logDate = today
                                      , deviceTimezone = Nothing
                                      , mealSlot = Just Dinner
                                      , item =
                                            { itemType = ItemRef.Product
                                            , id = "food-1"
                                            }
                                      , quantity = quantity
                                      , notes = Nothing
                                      }
                                    ]
                            , copying =
                                { phase = "loaded"
                                , date = "2026-05-30"
                                , logs = [ "log-3" ]
                                , error = Nothing
                                , copy = "copying:dinner"
                                , slotState = "loaded"
                                , suggestions = [ "dinner", "lunch" ]
                                }
                            , completed =
                                { phase = "loaded"
                                , date = "2026-05-30"
                                , logs = [ "log-3", "log-4" ]
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loaded"
                                , suggestions = [ "lunch" ]
                                }
                            , completedOut =
                                DiaryDay.LogsCopied today DiaryDay.DiaryUpdated
                            }
            , test "copying into a partly loaded or unknown day recomputes what to refresh" <|
                \_ ->
                    let
                        partialCopy : DiaryDay.Model
                        partialCopy =
                            initModel today
                                |> step
                                    (DiaryDay.LogsLoaded today (Ok [ breakfastLog ]))
                                |> step (DiaryDay.CopyLatestClicked dinnerSource)

                        unknownCopy : DiaryDay.Model
                        unknownCopy =
                            initModel today
                                |> step (DiaryDay.CopyLatestClicked dinnerSource)
                    in
                    { partial =
                        step
                            (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                            partialCopy
                            |> toScreen
                    , partialOut =
                        out
                            (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                            partialCopy
                    , unknown =
                        step
                            (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                            unknownCopy
                            |> toScreen
                    , unknownOut =
                        out
                            (DiaryDay.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                            unknownCopy
                    }
                        |> Expect.equal
                            { partial =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = [ "log-3", "log-4" ]
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , partialOut =
                                DiaryDay.LogsCopied today DiaryDay.DiaryUpdated
                            , unknown =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = []
                                , error = Nothing
                                , copy = "idle"
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , unknownOut =
                                DiaryDay.LogsCopied today DiaryDay.DiaryNeedsReload
                            }
            , test "a failed copy shows an error and an unauthorized copy resets and expires" <|
                \_ ->
                    let
                        copying : DiaryDay.Model
                        copying =
                            initModel today |> step (DiaryDay.CopyLatestClicked dinnerSource)
                    in
                    { request =
                        out
                            (DiaryDay.CopyLatestCompleted today (Err Client.NetworkError))
                            copying
                    , failed =
                        toScreen
                            (step
                                (DiaryDay.CopyLatestCompleted today (Err Client.NetworkError))
                                copying
                            )
                    , unauthorized =
                        out
                            (DiaryDay.CopyLatestCompleted
                                today
                                (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                            )
                            copying
                    , reset =
                        step
                            (DiaryDay.CopyLatestCompleted
                                today
                                (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                            )
                            copying
                            |> toScreen
                            |> .copy
                    }
                        |> Expect.equal
                            { request = DiaryDay.NoOp
                            , failed =
                                { phase = "loading"
                                , date = "2026-05-30"
                                , logs = []
                                , error = Nothing
                                , copy = "failed:" ++ networkErrorMessage
                                , slotState = "loading"
                                , suggestions = []
                                }
                            , unauthorized = DiaryDay.SessionExpired
                            , reset = "idle"
                            }
            ]
        , describe "derived behavior"
            [ test "slot calories are summed from the day's logs" <|
                \_ ->
                    initModel today
                        |> step
                            (DiaryDay.LogsLoaded
                                today
                                (Ok [ lunchLog, secondLunchLog, breakfastLog ])
                            )
                        |> step (DiaryDay.GoalLoaded today (Ok goalSnapshot))
                        |> DiaryDay.currentLogs
                        |> Maybe.withDefault []
                        |> DiaryDay.slotCalories Lunch
                        |> Expect.within (Expect.Absolute 0.0001) 347.5
            ]
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , date : String
    , logs : List String
    , error : Maybe String
    , copy : String
    , slotState : String
    , suggestions : List String
    }


toScreen : DiaryDay.Model -> Screen
toScreen model =
    { phase =
        case model.diary of
            DiaryDay.Loading _ ->
                "loading"

            DiaryDay.Loaded _ ->
                "loaded"

            DiaryDay.Failed _ _ ->
                "failed"
    , date = LocalDate.format model.currentDate
    , logs =
        DiaryDay.currentLogs model
            |> Maybe.withDefault []
            |> List.map .id
    , error =
        case model.diary of
            DiaryDay.Failed failedDate message ->
                if LocalDate.equals failedDate model.currentDate then
                    Just message

                else
                    Nothing

            _ ->
                Nothing
    , copy =
        case model.copyState of
            DiaryDay.CopyIdle ->
                "idle"

            DiaryDay.Copying slot ->
                "copying:" ++ MealSlot.toString slot

            DiaryDay.CopyFailed message ->
                "failed:" ++ message
    , slotState =
        case model.latestSlots of
            DiaryDay.LatestSlotsLoading ->
                "loading"

            DiaryDay.LatestSlotsLoaded _ _ ->
                "loaded"

            DiaryDay.LatestSlotsFailed ->
                "failed"
    , suggestions =
        case model.latestSlots of
            DiaryDay.LatestSlotsLoaded sourceDate sources ->
                if LocalDate.equals sourceDate model.currentDate then
                    List.map (.slot >> MealSlot.toString) sources

                else
                    []

            _ ->
                []
    }


loadedScreen : List String -> Screen
loadedScreen logs =
    { phase = "loaded"
    , date = "2026-05-30"
    , logs = logs
    , error = Nothing
    , copy = "idle"
    , slotState = "loading"
    , suggestions = []
    }


initModel : LocalDate -> DiaryDay.Model
initModel currentDate =
    DiaryDay.init
        { date = currentDate
        , calendarMonth = Nothing
        , today = today
        }
        |> Tuple.first


step : DiaryDay.Msg -> DiaryDay.Model -> DiaryDay.Model
step msg model =
    first (DiaryDay.update msg model)


out : DiaryDay.Msg -> DiaryDay.Model -> DiaryDay.OutMsg
out msg model =
    third (DiaryDay.update msg model)


goalSnapshot : GoalSnapshot
goalSnapshot =
    { requestedDate = today
    , effectiveFrom = Nothing
    , source = Default
    , targets =
        { calorieTarget = 2100
        , proteinTargetG = 150
        , carbsTargetG = 240
        , fatTargetG = 60
        }
    }


staleGoalSnapshot : GoalSnapshot
staleGoalSnapshot =
    { requestedDate = yesterday
    , effectiveFrom = Just yesterday
    , source = Saved
    , targets =
        { calorieTarget = 1800
        , proteinTargetG = 120
        , carbsTargetG = 180
        , fatTargetG = 60
        }
    }


today : LocalDate
today =
    date "2026-05-30"


yesterday : LocalDate
yesterday =
    date "2026-05-29"


tomorrow : LocalDate
tomorrow =
    date "2026-05-31"


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
                    -- This branch is unreachable because the fallback is a valid date.
                    today


productRef : LogItem
productRef =
    FoodLog.ProductLogItem
        { id = "food-1", name = "Chicken", brand = Nothing }


lunchLog : FoodLog
lunchLog =
    log "log-1"
        (Just Lunch)
        productRef
        [ nutrient "ENERGY_KCAL" "247.5" "kcal"
        , nutrient "PROTEIN_G" "46.5" "g"
        , nutrient "CARBS_G" "0" "g"
        , nutrient "FAT_G" "3.5" "g"
        ]


secondLunchLog : FoodLog
secondLunchLog =
    log "log-2" (Just Lunch) productRef [ nutrient "ENERGY_KCAL" "100" "kcal" ]


yesterdayLunchLog : FoodLog
yesterdayLunchLog =
    { lunchLog | id = "log-yesterday", logDate = yesterday }


breakfastLog : FoodLog
breakfastLog =
    log "log-3" (Just Breakfast) productRef [ nutrient "ENERGY_KCAL" "10" "kcal" ]


dinnerLog : FoodLog
dinnerLog =
    log "log-4" (Just Dinner) productRef [ nutrient "ENERGY_KCAL" "300" "kcal" ]


dinnerSlotResponse : Api.Logs.LatestSlotResponse
dinnerSlotResponse =
    { sourceDate = yesterday
    , mealSlot = Just Dinner
    , items = [ yesterdayDinnerLog ]
    }


lunchSlotResponse : Api.Logs.LatestSlotResponse
lunchSlotResponse =
    { sourceDate = yesterday
    , mealSlot = Just Lunch
    , items = [ yesterdayLunchLog ]
    }


dinnerSource : DiaryDay.LatestSlotSource
dinnerSource =
    { slot = Dinner
    , sourceDate = yesterday
    , logs = [ yesterdayDinnerLog ]
    }


yesterdayDinnerLog : FoodLog
yesterdayDinnerLog =
    { dinnerLog | id = "log-yesterday-dinner", logDate = yesterday }


log : String -> Maybe MealSlot -> LogItem -> List NutrientAmount -> FoodLog
log id mealSlot item nutrients =
    { id = id
    , logDate = date "2026-05-30"
    , deviceTimezone = Nothing
    , mealSlot = mealSlot
    , item = item
    , quantity = quantity
    , nutrients = nutrients
    , notes = Nothing
    }


quantity : Quantity
quantity =
    { amount = "150", unit = "g" }


nutrient : String -> String -> String -> NutrientAmount
nutrient code amount unit =
    { code = code, amount = amount, unit = unit }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
