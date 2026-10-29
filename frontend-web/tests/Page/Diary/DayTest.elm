module Page.Diary.DayTest exposing (tests)

import Api.Logs
import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (NutrientAmount, Quantity)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Date exposing (LocalDate)
import Page.Diary.Day as Day
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Diary.Day"
        [ test "a user copies yesterday's dinner into today" <|
            \_ ->
                loaded
                    |> step (Day.CopyLatestClicked dinnerSource)
                    |> step (Day.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                    |> finish
                        (\( model, outMsg ) ->
                            { screen = copyScreen model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { screen =
                                        { items = [ "Chicken", "Chicken" ]
                                        , sections = [ "Lunch", "Dinner" ]
                                        , feedback = ( Nothing, False )
                                        }
                                    , finalOut = Day.LogsCopied today Day.DiaryUpdated
                                    }
                        )
        , test "a user adds food to lunch" <|
            \_ ->
                loaded
                    |> step (Day.AddFoodClicked Lunch)
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (Day.Navigate (FoodSearch (Just today) (Just Lunch)))
                        )
        , test "a user opens a logged food" <|
            \_ ->
                loaded
                    |> step (Day.LogClicked "log-1")
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (Day.Navigate
                                        (FoodLogEntry "log-1" (Just today) (Just month))
                                    )
                        )
        ]


type alias CopyScreen =
    { items : List String
    , sections : List String
    , feedback : ( Maybe String, Bool )
    }


copyScreen : Day.Model -> CopyScreen
copyScreen model =
    let
        logs : List FoodLog
        logs =
            Day.currentLogs model |> Maybe.withDefault []
    in
    { items = List.map (.item >> FoodLog.itemName) logs
    , sections = visibleSections model.prefs logs
    , feedback =
        case model.copyState of
            Day.Copying _ ->
                ( Just loggingLabel, True )

            Day.CopyFailed message ->
                ( Just message, False )

            Day.CopyIdle ->
                ( Nothing, False )
    }


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



-- STORY PIPELINE


type alias Journey =
    Story.Journey Day.Model Day.OutMsg


step : Day.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd Day.update)


finish :
    (( Day.Model, Day.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loaded : Journey
loaded =
    Day.init { date = today, calendarMonth = Just month, today = today }
        |> Story.start
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


today : LocalDate
today =
    Fixtures.date "2026-05-30"


yesterday : LocalDate
yesterday =
    Fixtures.date "2026-05-29"


month : String
month =
    "2026-05"


loggingLabel : String
loggingLabel =
    I18n.en TidDiaryLogging


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


dinnerLog : FoodLog
dinnerLog =
    log "log-4" (Just Dinner) [ nutrient "ENERGY_KCAL" "300" "kcal" ]


yesterdayDinnerLog : FoodLog
yesterdayDinnerLog =
    { dinnerLog | id = "log-yesterday-dinner", logDate = yesterday }


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
