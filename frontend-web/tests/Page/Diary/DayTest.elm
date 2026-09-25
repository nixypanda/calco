module Page.Diary.DayTest exposing (tests)

import Api.Client as Client
import Api.Logs
import Data.FoodLog as FoodLog exposing (FoodLog, LogItem)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
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
            [ test "previous day navigation leaves current state intact" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            DiaryDay.update
                                DiaryDay.PreviousDayClicked
                                (initModel today)
                    in
                    ( LocalDate.format model.currentDate, outMsg )
                        |> Expect.equal
                            ( "2026-05-30"
                            , DiaryDay.Navigate (DiaryDay (Just "2026-05-29") Nothing)
                            )
            , test "a day that rolls over stops being the last navigable one" <|
                \_ ->
                    initModel today
                        |> DiaryDay.update (DiaryDay.TodayChanged tomorrow)
                        |> first
                        |> DiaryDay.update DiaryDay.NextDayClicked
                        |> third
                        |> Expect.equal
                            (DiaryDay.Navigate (DiaryDay (Just "2026-05-31") Nothing))
            , test "details action carries the selected date" <|
                \_ ->
                    DiaryDay.update DiaryDay.DetailsClicked (initModel yesterday)
                        |> third
                        |> Expect.equal
                            (DiaryDay.Navigate (NutritionDetails (Just "2026-05-29")))
            ]
        , describe "loading"
            [ test "diary stays loading until goals also load" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            DiaryDay.update (DiaryDay.LogsLoaded today (Ok [ lunchLog ])) emptyModel
                    in
                    ( model.diary, outMsg )
                        |> Expect.equal
                            ( DiaryDay.Loading
                                { date = today
                                , logs = Just [ lunchLog ]
                                , goal = Nothing
                                }
                            , DiaryDay.NoOp
                            )
            , test "goal success completes load when logs already arrived" <|
                \_ ->
                    let
                        afterLogs : DiaryDay.Model
                        afterLogs =
                            DiaryDay.update (DiaryDay.LogsLoaded today (Ok [ lunchLog ])) emptyModel
                                |> first

                        ( model, _, outMsg ) =
                            DiaryDay.update (DiaryDay.GoalLoaded today (Ok goalSnapshot)) afterLogs
                    in
                    ( model.diary, outMsg )
                        |> Expect.equal
                            ( DiaryDay.Loaded
                                { date = today
                                , logs = [ lunchLog ]
                                , goal = goalSnapshot
                                }
                            , DiaryDay.NoOp
                            )
            , test "load success filters logs that do not match the selected date" <|
                \_ ->
                    let
                        withGoal : DiaryDay.Model
                        withGoal =
                            DiaryDay.update (DiaryDay.GoalLoaded today (Ok goalSnapshot)) emptyModel
                                |> first
                    in
                    DiaryDay.update
                        (DiaryDay.LogsLoaded today (Ok [ lunchLog, yesterdayLunchLog ]))
                        withGoal
                        |> first
                        |> .diary
                        |> Expect.equal
                            (DiaryDay.Loaded
                                { date = today
                                , logs = [ lunchLog ]
                                , goal = goalSnapshot
                                }
                            )
            , test "load failure stores an error" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LogsLoaded today (Err Client.NetworkError))
                        { emptyModel
                            | diary =
                                DiaryDay.Loading
                                    { date = today, logs = Nothing, goal = Nothing }
                        }
                        |> first
                        |> .diary
                        |> Expect.equal (DiaryDay.Failed today networkErrorMessage)
            , test "stale load failure is ignored" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LogsLoaded yesterday (Err Client.NetworkError))
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            , test "goal unauthorized expires session" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.GoalLoaded
                            today
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        emptyModel
                        |> third
                        |> Expect.equal DiaryDay.SessionExpired
            , test "goal success after failure keeps partial goal loading state" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.GoalLoaded today (Ok goalSnapshot))
                        { emptyModel | diary = DiaryDay.Failed today "old" }
                        |> first
                        |> .diary
                        |> Expect.equal
                            (DiaryDay.Loading
                                { date = today
                                , logs = Nothing
                                , goal = Just goalSnapshot
                                }
                            )
            , test "latest slots success replaces loading state with every source" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LatestSlotsReceived today
                            (Ok
                                { slots =
                                    [ dinnerSlotResponse
                                    , lunchSlotResponse
                                    ]
                                }
                            )
                        )
                        { emptyModel | latestSlots = DiaryDay.LatestSlotsLoading }
                        |> first
                        |> .latestSlots
                        |> Expect.equal
                            (DiaryDay.LatestSlotsLoaded today [ dinnerSource, lunchSource ])
            , test "unknown meal slot in response is dropped" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LatestSlotsReceived today
                            (Ok
                                { slots =
                                    [ { dinnerSlotResponse | mealSlot = "brunch" }
                                    , lunchSlotResponse
                                    ]
                                }
                            )
                        )
                        { emptyModel | latestSlots = DiaryDay.LatestSlotsLoading }
                        |> first
                        |> .latestSlots
                        |> Expect.equal (DiaryDay.LatestSlotsLoaded today [ lunchSource ])
            , test "latest slots transport failure degrades to no suggestions" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LatestSlotsReceived today (Err Client.NetworkError))
                        { emptyModel | latestSlots = DiaryDay.LatestSlotsLoading }
                        |> first
                        |> .latestSlots
                        |> Expect.equal DiaryDay.LatestSlotsFailed
            , test "stale latest slots response is ignored" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LatestSlotsReceived yesterday
                            (Ok { slots = [ dinnerSlotResponse ] })
                        )
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            ]
        , describe "repeat logging"
            [ test "copy latest clicked builds copy requests from source logs" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.CopyLatestClicked dinnerSource)
                        emptyModel
                        |> third
                        |> Expect.equal
                            (DiaryDay.RequestCopyLatestSlot today
                                [ { logDate = today
                                  , deviceTimezone = yesterdayDinnerLog.deviceTimezone
                                  , mealSlot = Just "dinner"
                                  , item =
                                        { itemType = ItemRef.Product
                                        , id = "food-1"
                                        }
                                  , quantity = yesterdayDinnerLog.quantity
                                  , notes = yesterdayDinnerLog.notes
                                  }
                                ]
                            )
            , test "copy success appends returned logs without requesting reload" <|
                \_ ->
                    let
                        model : DiaryDay.Model
                        model =
                            { emptyModel
                                | diary =
                                    DiaryDay.Loaded
                                        { date = today
                                        , logs = [ breakfastLog ]
                                        , goal = goalSnapshot
                                        }
                                , latestSlots =
                                    DiaryDay.LatestSlotsLoaded
                                        today
                                        [ dinnerSource, lunchSource ]
                                , copyState = DiaryDay.Copying Dinner
                            }

                        ( next, _, outMsg ) =
                            DiaryDay.update
                                (DiaryDay.CopyLatestCompleted
                                    today
                                    (Ok { items = [ dinnerLog ] })
                                )
                                model
                    in
                    { diary = next.diary
                    , latestSlots = next.latestSlots
                    , copyState = next.copyState
                    , outMsg = outMsg
                    }
                        |> Expect.equal
                            { diary =
                                DiaryDay.Loaded
                                    { date = today
                                    , logs = [ breakfastLog, dinnerLog ]
                                    , goal = goalSnapshot
                                    }
                            , latestSlots =
                                DiaryDay.LatestSlotsLoaded today [ lunchSource ]
                            , copyState = DiaryDay.CopyIdle
                            , outMsg = DiaryDay.LogsCopied today DiaryDay.DiaryUpdated
                            }
            , test "copy success preserves partial load and does not reload" <|
                \_ ->
                    let
                        model : DiaryDay.Model
                        model =
                            { emptyModel
                                | diary =
                                    DiaryDay.Loading
                                        { date = today
                                        , logs = Just [ breakfastLog ]
                                        , goal = Nothing
                                        }
                                , copyState = DiaryDay.Copying Dinner
                            }

                        ( next, _, outMsg ) =
                            DiaryDay.update
                                (DiaryDay.CopyLatestCompleted
                                    today
                                    (Ok { items = [ dinnerLog ] })
                                )
                                model
                    in
                    ( next.diary, next.copyState, outMsg )
                        |> Expect.equal
                            ( DiaryDay.Loading
                                { date = today
                                , logs = Just [ breakfastLog, dinnerLog ]
                                , goal = Nothing
                                }
                            , DiaryDay.CopyIdle
                            , DiaryDay.LogsCopied today DiaryDay.DiaryUpdated
                            )
            , test "copy success reloads when existing logs are unknown" <|
                \_ ->
                    let
                        model : DiaryDay.Model
                        model =
                            { emptyModel | copyState = DiaryDay.Copying Dinner }

                        ( next, _, outMsg ) =
                            DiaryDay.update
                                (DiaryDay.CopyLatestCompleted
                                    today
                                    (Ok { items = [ dinnerLog ] })
                                )
                                model
                    in
                    { diary = next.diary
                    , latestSlots = next.latestSlots
                    , copyState = next.copyState
                    , outMsg = outMsg
                    }
                        |> Expect.equal
                            { diary =
                                DiaryDay.Loading
                                    { date = today, logs = Nothing, goal = Nothing }
                            , latestSlots = DiaryDay.LatestSlotsLoading
                            , copyState = DiaryDay.CopyIdle
                            , outMsg =
                                DiaryDay.LogsCopied today DiaryDay.DiaryNeedsReload
                            }
            , test "copy success with stale date is ignored" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.CopyLatestCompleted
                            yesterday
                            (Ok { items = [ yesterdayDinnerLog ] })
                        )
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            , test "copy failure stores display error" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.CopyLatestCompleted today (Err Client.NetworkError))
                        { emptyModel | copyState = DiaryDay.Copying Dinner }
                        |> first
                        |> .copyState
                        |> Expect.equal (DiaryDay.CopyFailed networkErrorMessage)
            , test "copy unauthorized resets copy state and expires session" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.CopyLatestCompleted
                            today
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        { emptyModel | copyState = DiaryDay.Copying Dinner }
                        |> (\( model, _, outMsg ) -> ( model.copyState, outMsg ))
                        |> Expect.equal ( DiaryDay.CopyIdle, DiaryDay.SessionExpired )
            ]
        , describe "derived behavior"
            [ test "slot calories are summed from snapshots" <|
                \_ ->
                    DiaryDay.slotCalories Lunch [ lunchLog, secondLunchLog, breakfastLog ]
                        |> Expect.within (Expect.Absolute 0.0001) 347.5
            ]
        , describe "navigation intents"
            [ test "add-food action navigates to search with selected meal slot" <|
                \_ ->
                    DiaryDay.update (DiaryDay.AddFoodClicked Lunch) emptyModel
                        |> third
                        |> Expect.equal
                            (DiaryDay.Navigate
                                (FoodSearch (Just "2026-05-30") (Just Lunch))
                            )
            , test "log row click navigates to log detail" <|
                \_ ->
                    DiaryDay.update (DiaryDay.LogClicked "log-1") emptyModel
                        |> third
                        |> Expect.equal
                            (DiaryDay.Navigate
                                (FoodLogEntry "log-1" (Just "2026-05-30") Nothing)
                            )
            , test "meals menu action navigates to meals" <|
                \_ ->
                    DiaryDay.update DiaryDay.MealsClicked emptyModel
                        |> third
                        |> Expect.equal (DiaryDay.Navigate MealList)
            ]
        ]


initModel : LocalDate -> DiaryDay.Model
initModel currentDate =
    DiaryDay.init
        { date = currentDate
        , calendarMonth = Nothing
        , today = today
        }
        |> Tuple.first


emptyModel : DiaryDay.Model
emptyModel =
    { currentDate = date "2026-05-30"
    , today = today
    , calendarMonth = Nothing
    , diary =
        DiaryDay.Loading
            { date = today
            , logs = Nothing
            , goal = Nothing
            }
    , latestSlots = DiaryDay.LatestSlotsLoaded today []
    , copyState = DiaryDay.CopyIdle
    , macroMode = DiaryDay.Grams
    , preferences = Nothing
    }


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
    , mealSlot = "dinner"
    , items = [ yesterdayDinnerLog ]
    }


lunchSlotResponse : Api.Logs.LatestSlotResponse
lunchSlotResponse =
    { sourceDate = yesterday
    , mealSlot = "lunch"
    , items = [ yesterdayLunchLog ]
    }


dinnerSource : DiaryDay.LatestSlotSource
dinnerSource =
    { slot = Dinner
    , sourceDate = yesterday
    , logs = [ yesterdayDinnerLog ]
    }


lunchSource : DiaryDay.LatestSlotSource
lunchSource =
    { slot = Lunch
    , sourceDate = yesterday
    , logs = [ yesterdayLunchLog ]
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
