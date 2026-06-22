module Page.Diary.DayTest exposing (tests)

import Api.Client as Client
import Data.FoodLog exposing (FoodLog, LogItem)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition exposing (NutrientAmount, Quantity)
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Day as DiaryDay
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Diary.Day"
        [ describe "initialization"
            [ test "valid date query param becomes current date" <|
                \_ ->
                    initModel (Just "2026-05-30")
                        |> .currentDate
                        |> LocalDate.format
                        |> Expect.equal "2026-05-30"
            , test "invalid date query param falls back to today" <|
                \_ ->
                    initModel (Just "not-a-date")
                        |> .currentDate
                        |> Expect.equal today
            , test "missing date query param falls back to today" <|
                \_ ->
                    initModel Nothing
                        |> .currentDate
                        |> Expect.equal today
            , test "future date query param is clamped to today" <|
                \_ ->
                    initModel (Just "2026-05-31")
                        |> .currentDate
                        |> Expect.equal today
            ]
        , describe "date navigation"
            [ test "previous day decrements selected date" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            DiaryDay.update
                                DiaryDay.PreviousDayClicked
                                (initModel (Just "2026-05-30"))
                    in
                    ( LocalDate.format model.currentDate, outMsg )
                        |> Expect.equal
                            ( "2026-05-29"
                            , DiaryDay.Navigate (DiaryDay (Just "2026-05-29"))
                            )
            , test "next day increments selected date" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            DiaryDay.update DiaryDay.NextDayClicked (initModel (Just "2026-05-29"))
                    in
                    ( LocalDate.format model.currentDate, outMsg )
                        |> Expect.equal
                            ( "2026-05-30"
                            , DiaryDay.Navigate (DiaryDay (Just "2026-05-30"))
                            )
            , test "next day does nothing when selected date is today" <|
                \_ ->
                    let
                        model : DiaryDay.Model
                        model =
                            initModel Nothing

                        ( next, _, outMsg ) =
                            DiaryDay.update DiaryDay.NextDayClicked model
                    in
                    ( next.currentDate, outMsg )
                        |> Expect.equal ( model.currentDate, DiaryDay.NoOp )
            ]
        , describe "loading"
            [ test "load started marks diary data as loading" <|
                \_ ->
                    DiaryDay.update
                        DiaryDay.LoadStarted
                        { emptyModel | diary = DiaryDay.Failed today "old" }
                        |> first
                        |> .diary
                        |> Expect.equal
                            (DiaryDay.Loading
                                { date = today, logs = Nothing, goal = Nothing }
                            )
            , test "diary stays loading until goals also load" <|
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
                        |> Expect.equal (DiaryDay.Failed today "Network error")
            , test "stale load failure is ignored" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.LogsLoaded yesterday (Err Client.NetworkError))
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            ]
        , describe "derived behavior"
            [ test "slot calories are summed from snapshots" <|
                \_ ->
                    DiaryDay.slotCalories Lunch [ lunchLog, secondLunchLog, breakfastLog ]
                        |> Expect.within (Expect.Absolute 0.0001) 347.5
            , test "daily calories come from totals ENERGY_KCAL" <|
                \_ ->
                    DiaryDay.dailyCalories summary
                        |> Expect.within (Expect.Absolute 0.0001) 247.5
            , test "macro totals calculate grams and percentages" <|
                \_ ->
                    let
                        totals : Nutrition.MacroTotals
                        totals =
                            Nutrition.macroTotals [ lunchLog ]
                    in
                    { protein = totals.protein
                    , carbs = totals.carbs
                    , fat = totals.fat
                    , proteinPct = round totals.proteinPct
                    , carbsPct = round totals.carbsPct
                    , fatPct = round totals.fatPct
                    }
                        |> Expect.equal
                            { protein = 46.5
                            , carbs = 0
                            , fat = 3.5
                            , proteinPct = 86
                            , carbsPct = 0
                            , fatPct = 14
                            }
            , test "macro mode toggles from grams to percent and back" <|
                \_ ->
                    let
                        ( percent, _, _ ) =
                            DiaryDay.update DiaryDay.MacroModeToggled emptyModel

                        ( grams, _, _ ) =
                            DiaryDay.update DiaryDay.MacroModeToggled percent
                    in
                    ( percent.macroMode, grams.macroMode )
                        |> Expect.equal ( DiaryDay.Percent, DiaryDay.Grams )
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
            , test "add-food action should preserve selected diary date in navigation" <|
                \_ ->
                    DiaryDay.update
                        (DiaryDay.AddFoodClicked Lunch)
                        { emptyModel
                            | currentDate = yesterday
                            , diary =
                                DiaryDay.Loaded
                                    { date = yesterday
                                    , logs = []
                                    , goal = yesterdayGoalSnapshot
                                    }
                        }
                        |> third
                        |> Expect.equal
                            (DiaryDay.Navigate
                                (FoodSearch (Just "2026-05-29") (Just Lunch))
                            )
            , test "log row click navigates to log detail" <|
                \_ ->
                    DiaryDay.update (DiaryDay.LogClicked "log-1") emptyModel
                        |> third
                        |> Expect.equal (DiaryDay.Navigate (FoodLogEntry "log-1"))
            , test "meals menu action navigates to meals" <|
                \_ ->
                    DiaryDay.update DiaryDay.MealsClicked emptyModel
                        |> third
                        |> Expect.equal (DiaryDay.Navigate MealList)
            ]
        ]


initModel : Maybe String -> DiaryDay.Model
initModel dateParam =
    DiaryDay.init { dateParam = dateParam, today = today }
        |> Tuple.first


emptyModel : DiaryDay.Model
emptyModel =
    { currentDate = date "2026-05-30"
    , today = today
    , diary =
        DiaryDay.Loading
            { date = today
            , logs = Nothing
            , goal = Nothing
            }
    , latestSlots = DiaryDay.LatestSlotsLoaded today []
    , copyState = DiaryDay.CopyIdle
    , macroMode = DiaryDay.Grams
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


yesterdayGoalSnapshot : GoalSnapshot
yesterdayGoalSnapshot =
    { requestedDate = yesterday
    , effectiveFrom = Just yesterday
    , source = Saved
    , targets =
        { calorieTarget = 2290
        , proteinTargetG = 160
        , carbsTargetG = 255
        , fatTargetG = 70
        }
    }


today : LocalDate
today =
    date "2026-05-30"


yesterday : LocalDate
yesterday =
    date "2026-05-29"


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
    { itemType = ItemRef.Product, id = "food-1", name = "Chicken", brand = Nothing }


lunchLog : FoodLog
lunchLog =
    log "log-1"
        (Just "lunch")
        productRef
        [ nutrient "ENERGY_KCAL" "247.5" "kcal"
        , nutrient "PROTEIN_G" "46.5" "g"
        , nutrient "CARBS_G" "0" "g"
        , nutrient "FAT_G" "3.5" "g"
        ]


secondLunchLog : FoodLog
secondLunchLog =
    log "log-2" (Just "lunch") productRef [ nutrient "ENERGY_KCAL" "100" "kcal" ]


yesterdayLunchLog : FoodLog
yesterdayLunchLog =
    { lunchLog | id = "log-yesterday", logDate = yesterday }


breakfastLog : FoodLog
breakfastLog =
    log "log-3" (Just "breakfast") productRef [ nutrient "ENERGY_KCAL" "10" "kcal" ]


summary : List NutrientAmount
summary =
    [ nutrient "ENERGY_KCAL" "247.5" "kcal"
    , nutrient "PROTEIN_G" "46.5" "g"
    , nutrient "CARBS_G" "0" "g"
    , nutrient "FAT_G" "3.5" "g"
    ]


log : String -> Maybe String -> LogItem -> List NutrientAmount -> FoodLog
log id mealSlot item nutrients =
    { id = id
    , logDate = date "2026-05-30"
    , deviceTimezone = Nothing
    , mealSlot = mealSlot
    , item = item
    , quantity = quantity
    , nutritionSummary = Nutrition.emptySummary
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
