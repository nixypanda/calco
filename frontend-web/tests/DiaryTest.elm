module DiaryTest exposing (tests)

import Api.Client as Client
import Data.FoodLog as FoodLog exposing (FoodLog, LogItem)
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Quantity exposing (Quantity)
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Index as Diary
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Diary.Index"
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
                            Diary.update Diary.PreviousDayClicked (initModel (Just "2026-05-30"))
                    in
                    ( LocalDate.format model.currentDate, outMsg )
                        |> Expect.equal ( "2026-05-29", Diary.Navigate (Diary (Just "2026-05-29")) )
            , test "next day increments selected date" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Diary.update Diary.NextDayClicked (initModel (Just "2026-05-29"))
                    in
                    ( LocalDate.format model.currentDate, outMsg )
                        |> Expect.equal ( "2026-05-30", Diary.Navigate (Diary (Just "2026-05-30")) )
            , test "next day does nothing when selected date is today" <|
                \_ ->
                    let
                        model : Diary.Model
                        model =
                            initModel Nothing

                        ( next, _, outMsg ) =
                            Diary.update Diary.NextDayClicked model
                    in
                    ( next.currentDate, outMsg )
                        |> Expect.equal ( model.currentDate, Diary.NoOp )
            ]
        , describe "loading"
            [ test "load started marks diary data as loading" <|
                \_ ->
                    Diary.update Diary.LoadStarted { emptyModel | diary = Diary.Failed today "old" }
                        |> first
                        |> .diary
                        |> Expect.equal (Diary.Loading today)
            , test "load success stores logs" <|
                \_ ->
                    let
                        ( model, _, outMsg ) =
                            Diary.update (Diary.LogsLoaded today (Ok [ lunchLog ])) emptyModel
                    in
                    ( model.diary, outMsg )
                        |> Expect.equal
                            ( Diary.Loaded today [ lunchLog ]
                            , Diary.NoOp
                            )
            , test "load success filters logs that do not match the selected date" <|
                \_ ->
                    Diary.update
                        (Diary.LogsLoaded today (Ok [ lunchLog, yesterdayLunchLog ]))
                        emptyModel
                        |> first
                        |> .diary
                        |> Expect.equal (Diary.Loaded today [ lunchLog ])
            , test "stale load success is ignored" <|
                \_ ->
                    Diary.update
                        (Diary.LogsLoaded yesterday (Ok [ yesterdayLunchLog ]))
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            , test "load failure stores an error" <|
                \_ ->
                    Diary.update
                        (Diary.LogsLoaded today (Err Client.NetworkError))
                        { emptyModel | diary = Diary.Loading today }
                        |> first
                        |> .diary
                        |> Expect.equal (Diary.Failed today "Network error")
            , test "stale load failure is ignored" <|
                \_ ->
                    Diary.update
                        (Diary.LogsLoaded yesterday (Err Client.NetworkError))
                        emptyModel
                        |> first
                        |> Expect.equal emptyModel
            ]
        , describe "derived behavior"
            [ test "logs are grouped into meal slots and other" <|
                \_ ->
                    FoodLog.groupLogs [ breakfastLog, lunchLog, dinnerLog, snackLog, otherLog ]
                        |> (\groups ->
                                List.map List.length
                                    [ groups.breakfast
                                    , groups.lunch
                                    , groups.dinner
                                    , groups.snack
                                    , groups.other
                                    ]
                           )
                        |> Expect.equal [ 1, 1, 1, 1, 1 ]
            , test "slot calories are summed from snapshots" <|
                \_ ->
                    Diary.slotCalories Lunch [ lunchLog, secondLunchLog, breakfastLog ]
                        |> Expect.within (Expect.Absolute 0.0001) 347.5
            , test "daily calories come from totals ENERGY_KCAL" <|
                \_ ->
                    Diary.dailyCalories summary
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
                            Diary.update Diary.MacroModeToggled emptyModel

                        ( grams, _, _ ) =
                            Diary.update Diary.MacroModeToggled percent
                    in
                    ( percent.macroMode, grams.macroMode )
                        |> Expect.equal ( Diary.Percent, Diary.Grams )
            ]
        , describe "navigation intents"
            [ test "add-food action navigates to search with selected meal slot" <|
                \_ ->
                    Diary.update (Diary.AddFoodClicked Lunch) emptyModel
                        |> third
                        |> Expect.equal (Diary.Navigate (FoodSearch (Just Lunch)))
            , test "log row click navigates to log detail" <|
                \_ ->
                    Diary.update (Diary.LogClicked "log-1") emptyModel
                        |> third
                        |> Expect.equal (Diary.Navigate (FoodLogDetail "log-1"))
            , test "meals menu action navigates to meals" <|
                \_ ->
                    Diary.update Diary.MealsClicked emptyModel
                        |> third
                        |> Expect.equal (Diary.Navigate Meals)
            ]
        ]


initModel : Maybe String -> Diary.Model
initModel dateParam =
    Diary.init { dateParam = dateParam, today = today }
        |> Tuple.first


emptyModel : Diary.Model
emptyModel =
    { currentDate = date "2026-05-30"
    , today = today
    , diary = Diary.Loaded today []
    , macroMode = Diary.Grams
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
    { itemType = "product", id = "food-1", name = "Chicken", brand = Nothing }


mealRef : LogItem
mealRef =
    { itemType = "meal", id = "meal-1", name = "Lunch meal", brand = Nothing }


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


dinnerLog : FoodLog
dinnerLog =
    log "log-4" (Just "dinner") productRef []


snackLog : FoodLog
snackLog =
    log "log-5" (Just "snack") productRef []


otherLog : FoodLog
otherLog =
    log "log-6" Nothing mealRef []


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
