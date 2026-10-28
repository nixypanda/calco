module Page.Diary.DayTest exposing (tests)

import Api.Client as Client
import Api.Logs
import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.ItemRef as ItemRef
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (NutrientAmount, Quantity)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Day as Day
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Day"
        [ test "a dinner copy fails once, retries, and then appears in the diary" <|
            \_ ->
                let
                    ( copying, copyOut ) =
                        stepOnce (Day.CopyLatestClicked dinnerSource) loaded

                    ( failed, failedOut ) =
                        stepOnce
                            (Day.CopyLatestCompleted today (Err Client.NetworkError))
                            copying

                    retried : Result String ( Day.Model, List Day.OutMsg )
                    retried =
                        runStepsResult stepWithOut
                            [ Day.CopyLatestClicked dinnerSource
                            , Day.CopyLatestCompleted today (Ok { items = [ dinnerLog ] })
                            ]
                            failed
                in
                case retried of
                    Ok ( final, outs ) ->
                        { request = copiedRequest copyOut
                        , copying = (toScreen copying).feedback
                        , failureOut = failedOut
                        , failed = (toScreen failed).feedback
                        , requests = List.filterMap copiedRequest outs
                        , finalOut = List.reverse outs |> List.head
                        , final =
                            ( (toScreen final).items
                            , (toScreen final).sections
                            , (toScreen final).feedback
                            )
                        }
                            |> Expect.equal
                                { request = Just copiedDinner
                                , copying = ( Just loggingLabel, True )
                                , failureOut = Day.NoOp
                                , failed = ( Just Fixtures.networkErrorMessage, False )
                                , requests = [ copiedDinner ]
                                , finalOut = Just (Day.LogsCopied today Day.DiaryUpdated)
                                , final =
                                    ( [ "Chicken", "Chicken" ]
                                    , [ "Lunch", "Dinner" ]
                                    , ( Nothing, False )
                                    )
                                }

                    Err message ->
                        Expect.fail message
        , test "stale diary data stays put, copy 401 expires, and a later 401 still expires" <|
            \_ ->
                let
                    ( afterLogs, logsOut ) =
                        stepOnce (Day.LogsLoaded yesterday (Ok [ staleLog ])) loaded

                    ( afterGoal, goalOut ) =
                        stepOnce (Day.GoalLoaded yesterday (Ok staleGoal)) afterLogs

                    ( afterSlots, slotsOut ) =
                        stepOnce
                            (Day.LatestSlotsReceived yesterday (Ok staleSlots))
                            afterGoal

                    staleLoaded : Day.Model
                    staleLoaded =
                        Day.init { date = yesterday, calendarMonth = Just month, today = yesterday }
                            |> Tuple.first
                            |> step (Day.LogsLoaded yesterday (Ok [ staleLog ]))
                            |> step (Day.GoalLoaded yesterday (Ok staleGoal))
                            |> step (Day.LatestSlotsReceived yesterday (Ok staleSlots))

                    staleWouldShow : StaleView
                    staleWouldShow =
                        let
                            screen : Screen
                            screen =
                                toScreen staleLoaded
                        in
                        { items = screen.items
                        , sections = screen.sections
                        , target = screen.target
                        , suggestion = screen.suggestion
                        }

                    ( copying, _ ) =
                        stepOnce (Day.CopyLatestClicked dinnerSource) afterSlots

                    ( afterCopy401, copyOut ) =
                        stepOnce
                            (Day.CopyLatestCompleted today (Err Fixtures.unauthorized))
                            copying

                    finalOut : Day.OutMsg
                    finalOut =
                        stepOnce (Day.LogsLoaded today (Err Fixtures.unauthorized))
                            afterCopy401
                            |> Tuple.second
                in
                { staleOuts = [ logsOut, goalOut, slotsOut ]
                , staleUnchanged = toScreen afterSlots == loadedScreen
                , staleWouldShow = staleWouldShow
                , copyOut = copyOut
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { staleOuts = [ Day.NoOp, Day.NoOp, Day.NoOp ]
                        , staleUnchanged = True
                        , staleWouldShow =
                            { items = [ "Tofu" ]
                            , sections = [ "Breakfast" ]
                            , target = Just "1200"
                            , suggestion = Just "2026-05-28"
                            }
                        , copyOut = Day.SessionExpired
                        , finalOut = Day.SessionExpired
                        }
        , test "prefs reveal every meal section, macros toggle, and day actions navigate" <|
            \_ ->
                let
                    loadedWithPrefs : Day.Model
                    loadedWithPrefs =
                        step (Day.PrefsLoaded (Ok allSlots)) loaded

                    ( clamped, clampOut ) =
                        stepOnce Day.NextDayClicked loadedWithPrefs

                    ( rollover, rolloverOut ) =
                        stepOnce Day.NextDayClicked
                            (step (Day.TodayChanged tomorrow) loadedWithPrefs)

                    actions : Result String ( Day.Model, List Day.OutMsg )
                    actions =
                        runStepsResult stepWithOut
                            [ Day.MacroModeToggled
                            , Day.PreviousDayClicked
                            , Day.DetailsClicked
                            , Day.AddFoodClicked Lunch
                            , Day.LogClicked "log-1"
                            ]
                            loadedWithPrefs
                in
                case actions of
                    Ok ( final, outs ) ->
                        { sections = (toScreen loadedWithPrefs).sections
                        , clamp = ( clampOut, (toScreen clamped).date )
                        , rollover = ( rolloverOut, (toScreen rollover).date )
                        , outs = List.drop 1 outs
                        , finalOut = List.reverse outs |> List.head
                        , macro = (toScreen final).macro
                        }
                            |> Expect.equal
                                { sections = sectionLabels
                                , clamp = ( Day.NoOp, "2026-05-30" )
                                , rollover =
                                    ( Day.Navigate (DiaryDay (Just tomorrow) (Just month))
                                    , "2026-05-30"
                                    )
                                , outs =
                                    [ Day.Navigate
                                        (DiaryDay (Just yesterday) (Just month))
                                    , Day.Navigate (NutritionDetails (Just today))
                                    , Day.Navigate (FoodSearch (Just today) (Just Lunch))
                                    , Day.Navigate
                                        (FoodLogEntry "log-1" (Just today) (Just month))
                                    ]
                                , finalOut =
                                    Just
                                        (Day.Navigate
                                            (FoodLogEntry "log-1" (Just today) (Just month))
                                        )
                                , macro = percentSummary
                                }

                    Err message ->
                        Expect.fail message
        ]



-- SCREEN PROJECTION


type alias StaleView =
    { items : List String
    , sections : List String
    , target : Maybe String
    , suggestion : Maybe String
    }


type alias Screen =
    { date : String
    , items : List String
    , sections : List String
    , feedback : ( Maybe String, Bool )
    , macro : String
    , target : Maybe String
    , suggestion : Maybe String
    }


toScreen : Day.Model -> Screen
toScreen model =
    let
        logs : List FoodLog
        logs =
            Day.currentLogs model |> Maybe.withDefault []
    in
    { date = LocalDate.format model.currentDate
    , items = List.map (.item >> FoodLog.itemName) logs
    , sections = visibleSections model.prefs logs
    , feedback =
        case model.copyState of
            Day.Copying _ ->
                ( Just loggingLabel, True )

            Day.CopyFailed message ->
                ( Just message, False )

            Day.CopyIdle ->
                ( Nothing, False )
    , macro =
        case model.macroMode of
            Day.Grams ->
                gramsSummary

            Day.Percent ->
                percentSummary
    , target = targetOf model
    , suggestion = suggestionOf model
    }


targetOf : Day.Model -> Maybe String
targetOf model =
    let
        snapshot : Maybe GoalSnapshot
        snapshot =
            case model.diary of
                Day.Loaded loadedState ->
                    Just loadedState.goal

                Day.Loading loading ->
                    loading.goal

                Day.Failed _ _ ->
                    Nothing
    in
    snapshot
        |> Maybe.map (.targets >> .calorieTarget >> round >> String.fromInt)


suggestionOf : Day.Model -> Maybe String
suggestionOf model =
    case model.latestSlots of
        Day.LatestSlotsLoaded _ sources ->
            sources
                |> List.filter (\source -> source.slot == Dinner)
                |> List.head
                |> Maybe.map (.sourceDate >> LocalDate.format)

        _ ->
            Nothing


visibleSections : Maybe DiaryPrefs -> List FoodLog -> List String
visibleSections prefs logs =
    MealSlot.all
        |> List.filter
            (\slot ->
                not (List.isEmpty (FoodLog.logsForSlot (Just slot) logs))
                    || (prefs
                            |> Maybe.map (DiaryPrefs.isEnabled slot)
                            |> Maybe.withDefault False
                       )
            )
        |> List.map (MealSlot.label I18n.defaultLanguage)


loadedScreen : Screen
loadedScreen =
    { date = "2026-05-30"
    , items = [ "Chicken" ]
    , sections = [ "Lunch" ]
    , feedback = ( Nothing, False )
    , macro = gramsSummary
    , target = Just "2100"
    , suggestion = Just "2026-05-29"
    }


type alias CopiedRequest =
    List String


copiedRequest : Day.OutMsg -> Maybe CopiedRequest
copiedRequest outMsg =
    case outMsg of
        Day.RequestCopyLatestSlot _ requests ->
            requests
                |> List.head
                |> Maybe.map
                    (\request ->
                        [ LocalDate.format request.logDate
                        , ItemRef.itemTypeToString request.item.itemType
                        , request.item.id
                        , request.quantity.amount ++ " " ++ request.quantity.unit
                        , request.mealSlot
                            |> Maybe.map MealSlot.toString
                            |> Maybe.withDefault ""
                        ]
                    )

        _ ->
            Nothing


copiedDinner : CopiedRequest
copiedDinner =
    [ "2026-05-30", "product", "food-1", "150 g", "dinner" ]



-- STEPS


step : Day.Msg -> Day.Model -> Day.Model
step msg model =
    Tuple.first (stepOnce msg model)


stepOnce : Day.Msg -> Day.Model -> ( Day.Model, Day.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            Day.update msg model
    in
    ( next, outMsg )


{-| A required message must move the diary or emit a route. Ignored messages are
reported instead of silently continuing with the old model.
-}
stepWithOut : Day.Msg -> Day.Model -> Maybe ( Day.Model, Day.OutMsg )
stepWithOut msg model =
    let
        ( next, outMsg ) =
            stepOnce msg model
    in
    if next == model && outMsg == Day.NoOp then
        Nothing

    else
        Just ( next, outMsg )



-- FIXTURES


loaded : Day.Model
loaded =
    Day.init { date = today, calendarMonth = Just month, today = today }
        |> Tuple.first
        |> step (Day.LogsLoaded today (Ok [ lunchLog ]))
        |> step (Day.GoalLoaded today (Ok goal))
        |> step
            (Day.LatestSlotsReceived today
                (Ok
                    { slots =
                        [ slotOn yesterday Dinner [ yesterdayDinnerLog ]
                        , slotOn yesterday Lunch [ lunchLog ]
                        ]
                    }
                )
            )


goal : GoalSnapshot
goal =
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


staleGoal : GoalSnapshot
staleGoal =
    { goal
        | requestedDate = yesterday
        , effectiveFrom = Just yesterday
        , source = Saved
        , targets =
            { calorieTarget = 1200
            , proteinTargetG = 60
            , carbsTargetG = 120
            , fatTargetG = 40
            }
    }


allSlots : DiaryPrefs
allSlots =
    { enabledMealSlots = MealSlot.all }


today : LocalDate
today =
    Fixtures.date "2026-05-30"


yesterday : LocalDate
yesterday =
    Fixtures.date "2026-05-29"


tomorrow : LocalDate
tomorrow =
    Fixtures.date "2026-05-31"


dayBefore : LocalDate
dayBefore =
    Fixtures.date "2026-05-28"


month : String
month =
    "2026-05"


sectionLabels : List String
sectionLabels =
    List.map (MealSlot.label I18n.defaultLanguage) MealSlot.all


loggingLabel : String
loggingLabel =
    I18n.en TidDiaryLogging


gramsSummary : String
gramsSummary =
    I18n.en (TidDiaryMacroSummaryGrams "0.0" "46.5" "3.5")


percentSummary : String
percentSummary =
    I18n.en (TidDiaryMacroSummaryPercent "0" "86" "14")


productRef : FoodLog.LogItem
productRef =
    FoodLog.ProductLogItem { id = "food-1", name = "Chicken", brand = Nothing }


lunchLog : FoodLog
lunchLog =
    log "log-1"
        (Just Lunch)
        [ nutrient "ENERGY_KCAL" "247.5" "kcal"
        , nutrient "PROTEIN_G" "46.5" "g"
        , nutrient "CARBS_G" "0" "g"
        , nutrient "FAT_G" "3.5" "g"
        ]


staleLog : FoodLog
staleLog =
    { lunchLog
        | id = "stale-log"
        , logDate = yesterday
        , mealSlot = Just Breakfast
        , item = FoodLog.ProductLogItem { id = "food-9", name = "Tofu", brand = Nothing }
        , quantity = { amount = "300", unit = "g" }
    }


staleDinnerLog : FoodLog
staleDinnerLog =
    { staleLog | mealSlot = Just Dinner }


dinnerLog : FoodLog
dinnerLog =
    log "log-4" (Just Dinner) [ nutrient "ENERGY_KCAL" "300" "kcal" ]


yesterdayDinnerLog : FoodLog
yesterdayDinnerLog =
    { dinnerLog | id = "log-yesterday-dinner", logDate = yesterday }


staleSlots : Api.Logs.LatestSlotsResponse
staleSlots =
    { slots = [ slotOn dayBefore Dinner [ staleDinnerLog ] ] }


dinnerSource : Day.LatestSlotSource
dinnerSource =
    { slot = Dinner, sourceDate = yesterday, logs = [ yesterdayDinnerLog ] }


slotOn : LocalDate -> MealSlot -> List FoodLog -> Api.Logs.LatestSlotResponse
slotOn sourceDate slot items =
    { sourceDate = sourceDate, mealSlot = Just slot, items = items }


log : String -> Maybe MealSlot -> List NutrientAmount -> FoodLog
log id mealSlot nutrients =
    { id = id
    , logDate = today
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = mealSlot
    , item = productRef
    , quantity = quantity
    , nutrients = nutrients
    , notes = Just "Post-workout"
    }


quantity : Quantity
quantity =
    { amount = "150", unit = "g" }


nutrient : String -> String -> String -> NutrientAmount
nutrient code amount unit =
    { code = code, amount = amount, unit = unit }
