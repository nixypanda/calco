module Page.Diary.DayTest exposing (tests)

import Api.Client as Client
import Api.Logs
import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition exposing (NutrientAmount, Quantity)
import Data.Route exposing (Route(..))
import Element
import Expect
import Fuzz
import Html.Attributes as Attr
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Diary.Day as Day
import Set
import Support.Fixtures as Fixtures
import Support.Fuzz as SupportFuzz
import Support.Story as Story
import Test exposing (Test, describe, fuzz, fuzz2, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (Selector)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env)
import Ui.Theme as Theme


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
        , fuzz (Fuzz.maybe SupportFuzz.mealSlotList)
            "skeleton slots follow enabled prefs and fall back to one neutral slot"
            skeletonSlotsProperty
        , fuzz2 SupportFuzz.mealSlotList
            SupportFuzz.foodLogList
            "visible slot sections keep prefs/log order, inclusion, uniqueness and unslotted last"
            visibleSlotSectionsProperty
        , test "a user copies yesterday's dinner after prefs fail" <|
            \_ ->
                loaded
                    |> step (Day.PrefsReceived (Err Client.NetworkError))
                    |> step (Day.CopyLatestClicked dinnerSource)
                    |> step (Day.CopyLatestCompleted today (Ok { items = [ dinnerLog ] }))
                    |> finish
                        (\( model, outMsg ) ->
                            Expect.all
                                [ \_ ->
                                    copyScreen model
                                        |> Expect.equal
                                            { items = [ "Chicken", "Chicken" ]
                                            , sections = [ "Lunch", "Dinner" ]
                                            , feedback = ( Nothing, False )
                                            }
                                , \_ ->
                                    outMsg
                                        |> Expect.equal (Day.LogsCopied today Day.DiaryUpdated)
                                , \_ ->
                                    Day.contentView env model
                                        |> Element.layout []
                                        |> Query.fromHtml
                                        |> Query.has
                                            [ Selector.text todayDisplay ]
                                , \_ ->
                                    Day.contentView env model
                                        |> Element.layout []
                                        |> Query.fromHtml
                                        |> Query.has
                                            [ Selector.text Fixtures.networkErrorMessage ]
                                ]
                                ()
                        )
        , test "loaded historical diary actions carry the selected date" <|
            \_ ->
                let
                    html : Query.Single Day.Msg
                    html =
                        Day.contentView env historicalLoaded
                            |> Element.layout []
                            |> Query.fromHtml

                    expectAction :
                        List Selector
                        -> Day.Msg
                        -> Day.OutMsg
                        -> Expect.Expectation
                    expectAction selectors expectedMsg expectedOut =
                        Expect.all
                            [ \_ ->
                                html
                                    |> Query.find selectors
                                    |> Event.simulate Event.click
                                    |> Event.expect expectedMsg
                            , \_ ->
                                outOf historicalLoaded expectedMsg
                                    |> Expect.equal expectedOut
                            ]
                            ()
                in
                Expect.all
                    [ \_ ->
                        expectAction
                            [ Selector.attribute
                                (Attr.attribute "data-testid" "open-calendar")
                            ]
                            Day.CalendarClicked
                            (Day.Navigate (DiaryCalendar (Just selectedMonth)))
                    , \_ ->
                        expectAction
                            [ Selector.attribute (Attr.attribute "role" "button")
                            , Selector.attribute
                                (Attr.attribute "aria-label" (I18n.en TidDiaryEditGoals))
                            ]
                            Day.GoalsClicked
                            (Day.Navigate
                                (GoalSettings (Just selectedDate) (Just selectedMonth))
                            )
                    , \_ ->
                        expectAction
                            [ Selector.attribute
                                (Attr.attribute "data-testid" "manage-meal-slots")
                            ]
                            Day.MealSlotsClicked
                            (Day.Navigate DiarySettings)
                    ]
                    ()
        , {- The controls are the same at every breakpoint; breakpoint-specific
             spacing, hover, and arrangement are browser-only.
          -}
          test "loaded diary exposes named calendar, today's goals, and meal-slot controls" <|
            \_ ->
                controlsVisible
        , test "failed current-date diary still exposes one manage meal slots action" <|
            \_ ->
                let
                    html : Query.Single Day.Msg
                    html =
                        Day.contentView env failedModel
                            |> Element.layout []
                            |> Query.fromHtml

                    manageButton : List Selector
                    manageButton =
                        [ Selector.attribute
                            (Attr.attribute "data-testid" "manage-meal-slots")
                        , Selector.attribute (Attr.attribute "role" "button")
                        ]
                in
                Expect.all
                    [ \_ ->
                        html
                            |> Query.findAll manageButton
                            |> Query.count (Expect.equal 1)
                    , \_ ->
                        html
                            |> Query.find manageButton
                            |> Query.has
                                [ Selector.text (I18n.en TidDiaryManageMealSlots) ]
                    , \_ ->
                        html
                            |> Query.find manageButton
                            |> Event.simulate Event.click
                            |> Event.expect Day.MealSlotsClicked
                    , \_ ->
                        outOf failedModel Day.MealSlotsClicked
                            |> Expect.equal (Day.Navigate DiarySettings)
                    ]
                    ()
        ]


type alias CopyScreen =
    { items : List String
    , sections : List String
    , feedback : ( Maybe String, Bool )
    }


outOf : Day.Model -> Day.Msg -> Day.OutMsg
outOf model msg =
    Day.update msg model
        |> (\( _, _, outMsg ) -> outMsg)


{-| A genuinely historical loaded diary: today is 2026-08-30 and the selected
date is 2026-07-20, so date-derived actions cannot accidentally use today.
-}
historicalLoaded : Day.Model
historicalLoaded =
    Day.init { date = selectedDate, calendarMonth = Just selectedMonth, today = today }
        |> Tuple.first
        |> Story.runSteps (Story.modelFromUpdate Day.update)
            [ Day.LogsLoaded selectedDate (Ok [ { lunchLog | logDate = selectedDate } ])
            , Day.GoalLoaded selectedDate (Ok { goal | requestedDate = selectedDate })
            , Day.PrefsReceived (Ok (enabledPrefs MealSlot.all))
            ]


failedModel : Day.Model
failedModel =
    Day.init { date = today, calendarMonth = Just month, today = today }
        |> Tuple.first
        |> Story.runSteps (Story.modelFromUpdate Day.update)
            [ Day.LogsLoaded today (Err Client.NetworkError) ]


controlsVisible : Expect.Expectation
controlsVisible =
    let
        html : Query.Single Day.Msg
        html =
            Day.contentView env historicalLoaded
                |> Element.layout []
                |> Query.fromHtml

        openCalendar : String
        openCalendar =
            I18n.en TidDiaryOpenCalendar

        openCalendarForDate : String
        openCalendarForDate =
            I18n.en (TidDiaryOpenCalendarFor selectedDisplay)

        editGoals : String
        editGoals =
            I18n.en TidDiaryEditGoals

        manageMealSlots : String
        manageMealSlots =
            I18n.en TidDiaryManageMealSlots
    in
    Expect.all
        [ \_ ->
            html
                |> Query.find
                    [ Selector.attribute (Attr.attribute "data-testid" "open-calendar")
                    , Selector.attribute (Attr.attribute "role" "button")
                    ]
                |> Query.has
                    [ Selector.attribute (Attr.attribute "title" openCalendar)
                    , Selector.attribute (Attr.attribute "aria-label" openCalendarForDate)
                    , Selector.attribute (Attr.attribute "tabIndex" "0")
                    ]
        , \_ ->
            html
                |> Query.find
                    [ Selector.attribute (Attr.attribute "role" "button")
                    , Selector.attribute (Attr.attribute "aria-label" editGoals)
                    ]
                |> Query.has
                    [ Selector.attribute (Attr.attribute "title" editGoals)
                    , Selector.attribute (Attr.attribute "tabIndex" "0")
                    ]
        , \_ ->
            html
                |> Query.findAll
                    [ Selector.attribute (Attr.attribute "role" "button")
                    , Selector.containing [ Selector.text manageMealSlots ]
                    ]
                |> Query.count (Expect.equal 1)
        ]
        ()


copyScreen : Day.Model -> CopyScreen
copyScreen model =
    let
        logs : List FoodLog
        logs =
            Day.currentLogs model |> Maybe.withDefault []
    in
    { items = List.map (.item >> FoodLog.itemName) logs
    , sections = visibleSections (Day.prefsForView model) logs
    , feedback =
        case model.copyState of
            Day.Copying _ ->
                ( Just loggingLabel, True )

            Day.CopyFailed message ->
                ( Just message, False )

            Day.CopyIdle ->
                ( Nothing, False )
    }


{-| The skeleton is the shape of the loaded slot list. Neutral prefs show one
slot; loaded prefs show enabled slots in `MealSlot.all` order, not prefs order.
-}
skeletonSlotsProperty : Maybe (List MealSlot) -> Expect.Expectation
skeletonSlotsProperty maybeEnabled =
    let
        expected : List MealSlot
        expected =
            case maybeEnabled of
                Nothing ->
                    [ Breakfast ]

                Just enabled ->
                    MealSlot.all
                        |> List.filter (\slot -> List.member slot enabled)
    in
    Day.skeletonSlots (Maybe.map enabledPrefs maybeEnabled)
        |> Expect.equal expected


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


{-| The loaded section rules as one property: order, inclusion, uniqueness,
and the unslotted section last. The expected list comes from `MealSlot.all`,
not from prefs' input order, so a bug that preserved the raw prefs order fails.
-}
visibleSlotSectionsProperty : List MealSlot -> List FoodLog -> Expect.Expectation
visibleSlotSectionsProperty enabled logs =
    let
        loadedSections : List Day.SlotSection
        loadedSections =
            Day.visibleSlotSections (Day.PrefsLoaded (enabledPrefs enabled)) logs

        pendingSections : List Day.SlotSection
        pendingSections =
            Day.visibleSlotSections Day.PrefsLoading logs

        failedSections : List Day.SlotSection
        failedSections =
            Day.visibleSlotSections (Day.PrefsFailed "offline") logs

        loggedSlots : List MealSlot
        loggedSlots =
            MealSlot.all
                |> List.filter
                    (\slot ->
                        not (List.isEmpty (FoodLog.logsForSlot (Just slot) logs))
                    )

        expectedLoadedSlots : List MealSlot
        expectedLoadedSlots =
            MealSlot.all
                |> List.filter
                    (\slot -> List.member slot enabled || List.member slot loggedSlots)

        slotsOf : List Day.SlotSection -> List MealSlot
        slotsOf sections =
            List.filterMap .slot sections

        uniqueSections : List Day.SlotSection -> Bool
        uniqueSections sections =
            let
                sectionKeys : List String
                sectionKeys =
                    List.map (.slot >> sectionKey) sections
            in
            List.length sectionKeys == Set.size (Set.fromList sectionKeys)

        unslottedLast : List Day.SlotSection -> Bool
        unslottedLast sections =
            let
                lastIndex : Int
                lastIndex =
                    List.length sections - 1
            in
            sections
                |> List.indexedMap (\index section -> ( index, section.slot ))
                |> List.all (\( index, slot ) -> slot /= Nothing || index == lastIndex)

        unslottedIncluded : List Day.SlotSection -> Bool
        unslottedIncluded sections =
            List.isEmpty (FoodLog.logsForSlot Nothing logs)
                || List.any (\section -> section.slot == Nothing) sections
    in
    Expect.all
        [ \_ -> slotsOf loadedSections |> Expect.equal expectedLoadedSlots
        , \_ -> slotsOf pendingSections |> Expect.equal loggedSlots
        , \_ -> slotsOf failedSections |> Expect.equal loggedSlots
        , \_ -> uniqueSections loadedSections |> Expect.equal True
        , \_ -> uniqueSections pendingSections |> Expect.equal True
        , \_ -> uniqueSections failedSections |> Expect.equal True
        , \_ -> unslottedLast loadedSections |> Expect.equal True
        , \_ -> unslottedLast pendingSections |> Expect.equal True
        , \_ -> unslottedLast failedSections |> Expect.equal True
        , \_ -> unslottedIncluded loadedSections |> Expect.equal True
        , \_ -> unslottedIncluded pendingSections |> Expect.equal True
        , \_ -> unslottedIncluded failedSections |> Expect.equal True
        ]
        ()


todayDisplay : String
todayDisplay =
    LocalDate.display I18n.defaultLanguage today


sectionKey : Maybe MealSlot -> String
sectionKey maybeSlot =
    maybeSlot
        |> Maybe.map MealSlot.toString
        |> Maybe.withDefault "unslotted"


enabledPrefs : List MealSlot -> DiaryPrefs
enabledPrefs enabledMealSlots =
    { enabledMealSlots = enabledMealSlots }


env : Env
env =
    { theme = Theme.light
    , device = { class = Element.Desktop, orientation = Element.Landscape }
    , language = EN_US
    }



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
    Story.start ( loadedModel, Day.RequestDiaryData )


loadedModel : Day.Model
loadedModel =
    Day.init { date = today, calendarMonth = Just month, today = today }
        |> Tuple.first
        |> Story.runSteps (Story.modelFromUpdate Day.update)
            [ Day.LogsLoaded today (Ok [ lunchLog ])
            , Day.GoalLoaded today (Ok goal)
            , Day.LatestSlotsReceived today
                (Ok
                    { slots =
                        [ slotOn yesterday Dinner [ yesterdayDinnerLog ]
                        , slotOn yesterday Lunch [ lunchLog ]
                        ]
                    }
                )
            ]


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
    Fixtures.date "2026-08-30"


selectedDate : LocalDate
selectedDate =
    Fixtures.date "2026-07-20"


selectedMonth : String
selectedMonth =
    "2026-07"


selectedDisplay : String
selectedDisplay =
    LocalDate.display I18n.defaultLanguage selectedDate


yesterday : LocalDate
yesterday =
    Fixtures.date "2026-08-29"


month : String
month =
    "2026-08"


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
