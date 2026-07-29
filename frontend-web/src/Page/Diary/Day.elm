module Page.Diary.Day exposing
    ( CopyState(..)
    , DiaryState(..)
    , LatestSlotSource
    , LatestSlotsState(..)
    , LoadedState
    , LoadingState
    , MacroMode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , slotCalories
    , update
    , view
    )

import Api.Client as Client
import Api.Logs exposing (BatchLogResponse, CreateLogRequest, LatestSlotResponse)
import Data.DiaryPreferences as DiaryPreferences exposing (DiaryPreferences)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalTargets)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition exposing (MacroTotals, NutrientAmount)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Ui
import Ui.Css as Css
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon
import Ui.Theme exposing (Mode(..), Theme)
import Ui.Typography as Typography
import View.Nutrients



-- MODEL


type MacroMode
    = Grams
    | Percent


type DiaryState
    = Loading LoadingState
    | Loaded LoadedState
    | Failed LocalDate String


type alias LoadingState =
    { date : LocalDate
    , logs : Maybe (List FoodLog)
    , goal : Maybe GoalSnapshot
    }


type alias LoadedState =
    { date : LocalDate
    , logs : List FoodLog
    , goal : GoalSnapshot
    }


type alias Model =
    { currentDate : LocalDate
    , today : LocalDate
    , calendarMonth : Maybe String
    , diary : DiaryState
    , latestSlots : LatestSlotsState
    , copyState : CopyState
    , macroMode : MacroMode
    , preferences : Maybe DiaryPreferences
    }


type LatestSlotsState
    = LatestSlotsLoading LocalDate Int (List LatestSlotSource)
    | LatestSlotsLoaded LocalDate (List LatestSlotSource)


type CopyState
    = CopyIdle
    | Copying MealSlot
    | CopyFailed String


type alias LatestSlotSource =
    { slot : MealSlot
    , sourceDate : LocalDate
    , logs : List FoodLog
    }


init :
    { dateParam : Maybe String
    , calendarMonth : Maybe String
    , today : LocalDate
    }
    -> ( Model, OutMsg )
init args =
    let
        currentDate : LocalDate
        currentDate =
            args.dateParam
                |> Maybe.andThen LocalDate.fromString
                |> Maybe.withDefault args.today
                |> LocalDate.clampTo args.today
    in
    ( { currentDate = currentDate
      , today = args.today
      , calendarMonth = args.calendarMonth
      , diary = loadingState currentDate
      , latestSlots = latestSlotsLoading currentDate
      , copyState = CopyIdle
      , macroMode = Grams
      , preferences = Nothing
      }
    , RequestDiaryData currentDate
    )



-- UPDATE


type Msg
    = LoadStarted
    | LogsLoaded LocalDate (Result Client.ApiError (List FoodLog))
    | GoalLoaded LocalDate (Result Client.ApiError GoalSnapshot)
    | PreferencesLoaded (Result Client.ApiError DiaryPreferences)
    | LatestSlotLoaded LocalDate MealSlot (Result Client.ApiError LatestSlotResponse)
    | CopyLatestClicked LatestSlotSource
    | CopyLatestCompleted LocalDate (Result Client.ApiError BatchLogResponse)
    | PreviousDayClicked
    | NextDayClicked
    | MacroModeToggled
    | AddFoodClicked MealSlot
    | LogClicked String
    | MealsClicked


type OutMsg
    = NoOp
    | RequestDiaryData LocalDate
    | RequestCopyLatestSlot LocalDate (List CreateLogRequest)
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LoadStarted ->
            case model.diary of
                Loading loading ->
                    if LocalDate.equals loading.date model.currentDate then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model
                            | diary = loadingState model.currentDate
                            , latestSlots = latestSlotsLoading model.currentDate
                            , copyState = CopyIdle
                          }
                        , Cmd.none
                        , NoOp
                        )

                _ ->
                    ( { model
                        | diary = loadingState model.currentDate
                        , latestSlots = latestSlotsLoading model.currentDate
                        , copyState = CopyIdle
                      }
                    , Cmd.none
                    , NoOp
                    )

        LogsLoaded requestDate result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok logs ->
                        ( { model | diary = applyLogsLoaded requestDate logs model.diary }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        failure requestDate error model

        GoalLoaded requestDate result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok snapshot ->
                        ( { model | diary = applyGoalLoaded requestDate snapshot model.diary }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        failure requestDate error model

        PreferencesLoaded result ->
            case result of
                Ok preferences ->
                    ( { model | preferences = Just preferences }, Cmd.none, NoOp )

                Err error ->
                    failure model.currentDate error model

        LatestSlotLoaded requestDate slot result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model
                            | latestSlots =
                                applyLatestSlotLoaded
                                    requestDate
                                    { slot = slot
                                    , sourceDate = response.sourceDate
                                    , logs = response.items
                                    }
                                    model.latestSlots
                          }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( model, Cmd.none, SessionExpired )

                        else
                            ( { model
                                | latestSlots =
                                    applyLatestSlotUnavailable
                                        requestDate
                                        model.latestSlots
                              }
                            , Cmd.none
                            , NoOp
                            )

        CopyLatestClicked source ->
            ( { model | copyState = Copying source.slot }
            , Cmd.none
            , source.logs
                |> List.map (copyRequestFromLog model.currentDate source.slot)
                |> RequestCopyLatestSlot model.currentDate
            )

        CopyLatestCompleted requestDate result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        case applyCopiedLogs requestDate response.items model.diary of
                            Just diary ->
                                ( { model
                                    | copyState = CopyIdle
                                    , diary = diary
                                    , latestSlots =
                                        removeLatestSlotSource
                                            requestDate
                                            (copiedSlotFromState model.copyState)
                                            model.latestSlots
                                  }
                                , Cmd.none
                                , NoOp
                                )

                            Nothing ->
                                ( { model
                                    | copyState = CopyIdle
                                    , diary = loadingState requestDate
                                    , latestSlots = latestSlotsLoading requestDate
                                  }
                                , Cmd.none
                                , RequestDiaryData requestDate
                                )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( { model | copyState = CopyIdle }, Cmd.none, SessionExpired )

                        else
                            ( { model
                                | copyState = CopyFailed (Client.displayError error)
                              }
                            , Cmd.none
                            , NoOp
                            )

        PreviousDayClicked ->
            let
                previous : LocalDate
                previous =
                    LocalDate.addDays -1 model.currentDate
            in
            ( { model
                | currentDate = previous
                , diary = loadingState previous
                , latestSlots = latestSlotsLoading previous
                , copyState = CopyIdle
              }
            , Cmd.none
            , Navigate
                (DiaryDay
                    (Just (LocalDate.format previous))
                    model.calendarMonth
                )
            )

        NextDayClicked ->
            case LocalDate.nextOnOrBefore model.today model.currentDate of
                Just next ->
                    ( { model
                        | currentDate = next
                        , diary = loadingState next
                        , latestSlots = latestSlotsLoading next
                        , copyState = CopyIdle
                      }
                    , Cmd.none
                    , Navigate
                        (DiaryDay
                            (Just (LocalDate.format next))
                            model.calendarMonth
                        )
                    )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        MacroModeToggled ->
            ( { model | macroMode = toggleMacroMode model.macroMode }, Cmd.none, NoOp )

        AddFoodClicked slot ->
            ( model
            , Cmd.none
            , Navigate (FoodSearch (Just (LocalDate.format model.currentDate)) (Just slot))
            )

        LogClicked id ->
            ( model
            , Cmd.none
            , Navigate (FoodLogEntry id (Just (LocalDate.format model.currentDate)))
            )

        MealsClicked ->
            ( model, Cmd.none, Navigate MealList )


failure : LocalDate -> Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure requestDate =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | diary = Failed requestDate message }
        }


loadingState : LocalDate -> DiaryState
loadingState date =
    Loading
        { date = date
        , logs = Nothing
        , goal = Nothing
        }


latestSlotsLoading : LocalDate -> LatestSlotsState
latestSlotsLoading date =
    LatestSlotsLoading date (List.length repeatableSlots) []


repeatableSlots : List MealSlot
repeatableSlots =
    MealSlot.all


applyLatestSlotLoaded :
    LocalDate
    -> LatestSlotSource
    -> LatestSlotsState
    -> LatestSlotsState
applyLatestSlotLoaded requestDate source state =
    case state of
        LatestSlotsLoading date remaining sources ->
            if LocalDate.equals date requestDate then
                finishLatestSlotLoad date (remaining - 1) (source :: sources)

            else
                state

        LatestSlotsLoaded date sources ->
            if LocalDate.equals date requestDate then
                LatestSlotsLoaded date (source :: sources)

            else
                state


applyLatestSlotUnavailable : LocalDate -> LatestSlotsState -> LatestSlotsState
applyLatestSlotUnavailable requestDate state =
    case state of
        LatestSlotsLoading date remaining sources ->
            if LocalDate.equals date requestDate then
                finishLatestSlotLoad date (remaining - 1) sources

            else
                state

        LatestSlotsLoaded _ _ ->
            state


removeLatestSlotSource : LocalDate -> Maybe MealSlot -> LatestSlotsState -> LatestSlotsState
removeLatestSlotSource requestDate maybeSlot state =
    case maybeSlot of
        Just slot ->
            case state of
                LatestSlotsLoading date remaining sources ->
                    if LocalDate.equals date requestDate then
                        LatestSlotsLoading date remaining (removeSource slot sources)

                    else
                        state

                LatestSlotsLoaded date sources ->
                    if LocalDate.equals date requestDate then
                        LatestSlotsLoaded date (removeSource slot sources)

                    else
                        state

        Nothing ->
            state


removeSource : MealSlot -> List LatestSlotSource -> List LatestSlotSource
removeSource slot sources =
    List.filter (\source -> source.slot /= slot) sources


finishLatestSlotLoad : LocalDate -> Int -> List LatestSlotSource -> LatestSlotsState
finishLatestSlotLoad date remaining sources =
    if remaining <= 0 then
        LatestSlotsLoaded date sources

    else
        LatestSlotsLoading date remaining sources


latestSlotSourceFor : LocalDate -> MealSlot -> LatestSlotsState -> Maybe LatestSlotSource
latestSlotSourceFor currentDate slot state =
    let
        matchingSource : List LatestSlotSource -> Maybe LatestSlotSource
        matchingSource sources =
            sources
                |> List.filter
                    (\source -> source.slot == slot)
                |> List.head
    in
    case state of
        LatestSlotsLoading date _ sources ->
            if LocalDate.equals date currentDate then
                matchingSource sources

            else
                Nothing

        LatestSlotsLoaded date sources ->
            if LocalDate.equals date currentDate then
                matchingSource sources

            else
                Nothing


copyRequestFromLog : LocalDate -> MealSlot -> FoodLog -> CreateLogRequest
copyRequestFromLog targetDate slot log =
    { logDate = targetDate
    , deviceTimezone = log.deviceTimezone
    , mealSlot = Just (MealSlot.toString slot)
    , item =
        { itemType = log.item.itemType
        , id = log.item.id
        }
    , quantity = log.quantity
    , notes = log.notes
    }


copiedSlotFromState : CopyState -> Maybe MealSlot
copiedSlotFromState copyState =
    case copyState of
        Copying slot ->
            Just slot

        _ ->
            Nothing


applyCopiedLogs : LocalDate -> List FoodLog -> DiaryState -> Maybe DiaryState
applyCopiedLogs requestDate copiedLogs diary =
    let
        matchingLogs : List FoodLog
        matchingLogs =
            FoodLog.logsForDate requestDate copiedLogs
    in
    case diary of
        Loaded loaded ->
            if LocalDate.equals loaded.date requestDate then
                Just (Loaded { loaded | logs = loaded.logs ++ matchingLogs })

            else
                Nothing

        Loading loading ->
            if LocalDate.equals loading.date requestDate then
                loading.logs
                    |> Maybe.map
                        (\logs ->
                            toLoadedOrLoading
                                { loading | logs = Just (logs ++ matchingLogs) }
                        )

            else
                Nothing

        Failed _ _ ->
            Nothing


applyLogsLoaded : LocalDate -> List FoodLog -> DiaryState -> DiaryState
applyLogsLoaded requestDate logs diary =
    let
        filteredLogs : List FoodLog
        filteredLogs =
            FoodLog.logsForDate requestDate logs
    in
    case diary of
        Loading loading ->
            toLoadedOrLoading
                { loading | date = requestDate, logs = Just filteredLogs }

        Loaded loaded ->
            toLoadedOrLoading
                { date = requestDate
                , logs = Just filteredLogs
                , goal = Just loaded.goal
                }

        Failed _ _ ->
            toLoadedOrLoading
                { date = requestDate
                , logs = Just filteredLogs
                , goal = Nothing
                }


applyGoalLoaded : LocalDate -> GoalSnapshot -> DiaryState -> DiaryState
applyGoalLoaded requestDate snapshot diary =
    case diary of
        Loading loading ->
            toLoadedOrLoading
                { loading | date = requestDate, goal = Just snapshot }

        Loaded loaded ->
            toLoadedOrLoading
                { date = requestDate
                , logs = Just loaded.logs
                , goal = Just snapshot
                }

        Failed _ _ ->
            toLoadedOrLoading
                { date = requestDate
                , logs = Nothing
                , goal = Just snapshot
                }


toLoadedOrLoading : LoadingState -> DiaryState
toLoadedOrLoading loading =
    case ( loading.logs, loading.goal ) of
        ( Just logs, Just goal ) ->
            Loaded
                { date = loading.date
                , logs = logs
                , goal = goal
                }

        _ ->
            Loading loading


toggleMacroMode : MacroMode -> MacroMode
toggleMacroMode mode =
    case mode of
        Grams ->
            Percent

        Percent ->
            Grams


slotCalories : MealSlot -> List FoodLog -> Float
slotCalories slot logs =
    logs
        |> FoodLog.logsForSlot slot
        |> List.map (.nutrients >> Nutrition.caloriesFrom)
        |> List.sum



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    let
        logs : List FoodLog
        logs =
            diaryLogs model.currentDate model.diary
    in
    Ui.pageContainer device
        (dateCard theme model device
            :: (case activeDiaryError model.currentDate model.diary of
                    Just message ->
                        [ Ui.errorBanner theme message ]

                    Nothing ->
                        copyErrorView theme model.copyState
                            ++ [ logGroupsView theme device model logs ]
               )
        )


dateCard : Theme -> Model -> Device -> Element Msg
dateCard theme model device =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare model.currentDate model.today == LT

        logs : List FoodLog
        logs =
            diaryLogs model.currentDate model.diary
    in
    Ui.card theme
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Ui.iconButton device
                theme
                { icon = Icon.ChevronLeft, title = "Previous Day", onPress = PreviousDayClicked }
            , Element.el
                [ Element.width Element.fill
                , Font.center
                ]
                (Typography.sectionTitle theme (LocalDate.display model.currentDate))
            , if canGoNext then
                Ui.iconButton device
                    theme
                    { icon = Icon.ChevronRight, title = "Next Day", onPress = NextDayClicked }

              else
                Ui.disabledIconButton theme { icon = Icon.ChevronRight }
            ]
        , Ui.hairline theme
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = DesignTokens.space8, right = 0, bottom = 0, left = 0 }
            ]
            [ case loadedGoalTargets model.currentDate model.diary of
                Just targets ->
                    totalsView theme targets (Nutrition.totalsFromLogs logs)

                Nothing ->
                    totalsView theme loadingGoalTargets (Nutrition.totalsFromLogs logs)
            ]
        ]


totalsView : Theme -> GoalTargets -> List NutrientAmount -> Element Msg
totalsView theme targets summary =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ View.Nutrients.macroBar theme
            { label = "Calories"
            , value = Nutrition.caloriesFrom summary
            , unit = "kcal"
            , color = theme.calorieAccent
            , max = targets.calorieTarget
            }
        , View.Nutrients.macroBar theme
            { label = "Protein"
            , value = summaryAmount "PROTEIN_G" summary
            , unit = "g"
            , color = theme.proteinAccent
            , max = targets.proteinTargetG
            }
        , View.Nutrients.macroBar theme
            { label = "Carbs"
            , value = summaryAmount "CARBS_G" summary
            , unit = "g"
            , color = theme.carbsAccent
            , max = targets.carbsTargetG
            }
        , View.Nutrients.macroBar theme
            { label = "Fat"
            , value = summaryAmount "FAT_G" summary
            , unit = "g"
            , color = theme.fatAccent
            , max = targets.fatTargetG
            }
        ]


summaryAmount : String -> List NutrientAmount -> Float
summaryAmount code summary =
    Nutrition.summaryValue code summary
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


diaryLogs : LocalDate -> DiaryState -> List FoodLog
diaryLogs currentDate diary =
    case diary of
        Loaded loaded ->
            if LocalDate.equals loaded.date currentDate then
                loaded.logs

            else
                []

        Loading loading ->
            if LocalDate.equals loading.date currentDate then
                Maybe.withDefault [] loading.logs

            else
                []

        _ ->
            []


loadedGoalTargets : LocalDate -> DiaryState -> Maybe GoalTargets
loadedGoalTargets currentDate diary =
    case diary of
        Loaded loaded ->
            if LocalDate.equals loaded.date currentDate then
                Just loaded.goal.targets

            else
                Nothing

        Loading loading ->
            if LocalDate.equals loading.date currentDate then
                Maybe.map .targets loading.goal

            else
                Nothing

        _ ->
            Nothing


loadingGoalTargets : GoalTargets
loadingGoalTargets =
    { calorieTarget = 0
    , proteinTargetG = 0
    , carbsTargetG = 0
    , fatTargetG = 0
    }


activeDiaryError : LocalDate -> DiaryState -> Maybe String
activeDiaryError currentDate diary =
    case diary of
        Failed date message ->
            if LocalDate.equals date currentDate then
                Just message

            else
                Nothing

        _ ->
            Nothing


copyErrorView : Theme -> CopyState -> List (Element Msg)
copyErrorView theme copyState =
    case copyState of
        CopyFailed message ->
            [ Ui.errorBanner theme message ]

        _ ->
            []


type alias SlotSection =
    { slot : MealSlot
    , logs : List FoodLog
    }


logGroupsView : Theme -> Device -> Model -> List FoodLog -> Element Msg
logGroupsView theme device model logs =
    let
        section : MealSlot -> SlotSection
        section slot =
            { slot = slot, logs = FoodLog.logsForSlot slot logs }

        otherSection : SlotSection
        otherSection =
            section Other
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        (List.map section MealSlot.all
            |> List.filter (shouldShowSection model.preferences)
            |> List.map (slotView theme device model)
            |> (\sections ->
                    sections
                        ++ [ if List.isEmpty otherSection.logs then
                                Element.none

                             else
                                slotView theme device model otherSection
                           ]
               )
        )


shouldShowSection : Maybe DiaryPreferences -> SlotSection -> Bool
shouldShowSection maybePreferences section =
    not (List.isEmpty section.logs)
        || (maybePreferences
                |> Maybe.map (DiaryPreferences.isEnabled section.slot)
                |> Maybe.withDefault False
           )


slotView : Theme -> Device -> Model -> SlotSection -> Element Msg
slotView theme device model section =
    let
        totals : MacroTotals
        totals =
            Nutrition.macroTotals section.logs
    in
    mealSlotCard theme
        device
        section.slot
        (mealSlotHeader theme model.macroMode section totals)
        (Ui.hairline theme
            :: (if List.isEmpty section.logs then
                    [ emptySlotView theme device model section.slot ]

                else
                    List.map (logRow theme) section.logs
               )
            ++ (case section.slot of
                    Other ->
                        []

                    _ ->
                        [ Ui.hairline theme
                        , Ui.fullWidthGhostButton
                            device
                            theme
                            "+ Add Food"
                            (AddFoodClicked section.slot)
                        ]
               )
        )


emptySlotView : Theme -> Device -> Model -> MealSlot -> Element Msg
emptySlotView theme device model slot =
    case latestSlotSourceFor model.currentDate slot model.latestSlots of
        Just source ->
            emptySlotBody
                (latestSlotButton
                    device
                    theme
                    (copyLatestLabel model.copyState source)
                    (CopyLatestClicked source)
                )

        Nothing ->
            emptySlotBody
                (Element.el
                    [ Font.color theme.textMuted
                    , Element.centerX
                    , Element.centerY
                    ]
                    (Element.text "No items")
                )


emptySlotBody : Element Msg -> Element Msg
emptySlotBody content =
    Element.el
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        ]
        (Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 24)
            ]
            content
        )


latestSlotButton : Device -> Theme -> String -> Msg -> Element Msg
latestSlotButton device theme label msg =
    Input.button
        [ Element.width Element.fill
        , Element.height (Element.px 24)
        , Border.rounded DesignTokens.radiusPill
        , Font.color theme.brandBlue
        , Font.medium
        , Font.center
        , if Ui.isSmall device then
            Element.mouseOver []

          else
            Element.mouseOver [ Background.color theme.brandBlueSoft ]
        , Element.htmlAttribute (Html.Attributes.class "ui-motion ui-pressable")
        ]
        { onPress = Just msg
        , label = Element.text label
        }


copyLatestLabel : CopyState -> LatestSlotSource -> String
copyLatestLabel copyState source =
    case copyState of
        Copying copyingSlot ->
            if copyingSlot == source.slot then
                "Logging..."

            else
                logLatestLabel source

        _ ->
            logLatestLabel source


logLatestLabel : LatestSlotSource -> String
logLatestLabel source =
    "Log latest from " ++ LocalDate.display source.sourceDate


mealSlotHeader :
    Theme
    -> MacroMode
    -> SlotSection
    -> MacroTotals
    -> Element Msg
mealSlotHeader theme macroMode section totals =
    let
        sectionKcal : Float
        sectionKcal =
            section.logs
                |> List.map (.nutrients >> Nutrition.caloriesFrom)
                |> List.sum
    in
    Element.row
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        , Element.spacing DesignTokens.space12
        ]
        [ Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
            [ Typography.sectionTitle theme (MealSlot.label section.slot)
            , Input.button []
                { onPress = Just MacroModeToggled
                , label = Typography.mutedCaption theme (macroSummary macroMode totals)
                }
            ]
        , Typography.mutedCaption theme
            (String.fromInt (round sectionKcal) ++ " kcal")
        ]


mealSlotHeaderHeight : Int
mealSlotHeaderHeight =
    118


mealSlotFade : Theme -> Element msg
mealSlotFade theme =
    let
        gradient : String
        gradient =
            case theme.mode of
                Light ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(255,255,255,0) 0%, "
                        ++ "rgba(255,255,255,0) 25%, "
                        ++ "rgba(255,255,255,0.48) 85%, "
                        ++ Css.toCssColor theme.cardBg
                        ++ " 100%)"

                Dark ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(0,0,0,0.25) 0%, "
                        ++ "rgba(0,0,0,0.55) 45%, "
                        ++ "rgba(0,0,0,0.85) 75%, "
                        ++ Css.toCssColor theme.cardBg
                        ++ " 100%)"
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.htmlAttribute (Html.Attributes.style "background-image" gradient)
        ]
        Element.none


mealSlotCard : Theme -> Device -> MealSlot -> Element Msg -> List (Element Msg) -> Element Msg
mealSlotCard theme device slot header bodyChildren =
    case slot of
        Other ->
            Ui.card theme (header :: bodyChildren)

        _ ->
            Ui.heroCard theme
                { header = header
                , body = bodyChildren
                , mediaHeader =
                    Just
                        { height = mealSlotHeaderHeight
                        , backgroundAttrs = mealSlotBackground slot
                        , fade = Just (mealSlotFade theme)
                        , contentPadding =
                            { top = 38
                            , right = mealSlotHorizontalPadding device
                            , bottom = 20
                            , left = mealSlotHorizontalPadding device
                            }
                        }
                }


mealSlotHorizontalPadding : Device -> Int
mealSlotHorizontalPadding device =
    if Ui.isSmall device then
        16

    else
        34


mealSlotBackground : MealSlot -> List (Element.Attribute msg)
mealSlotBackground slot =
    case mealSlotImage slot of
        Just image ->
            [ Element.htmlAttribute
                (Html.Attributes.style
                    "background-image"
                    ("url(\"" ++ image.url ++ "\")")
                )
            , Element.htmlAttribute
                (Html.Attributes.style
                    "background-size"
                    "max(100%, 1120px) auto"
                )
            , Element.htmlAttribute
                (Html.Attributes.style
                    "background-position"
                    (image.focusX ++ " top")
                )
            , Element.htmlAttribute
                (Html.Attributes.style "background-repeat" "no-repeat")
            ]

        Nothing ->
            []


mealSlotImage : MealSlot -> Maybe { url : String, focusX : String }
mealSlotImage slot =
    case slot of
        Breakfast ->
            Just { url = "/assets/breakfast.png", focusX = "13%" }

        Lunch ->
            Just { url = "/assets/lunch.png", focusX = "50%" }

        Dinner ->
            Just { url = "/assets/dinner.png", focusX = "47%" }

        Snack ->
            Just { url = "/assets/snacks.png", focusX = "82%" }

        LateNightSnack ->
            Just { url = "/assets/late-night-snack.png", focusX = "73%" }

        Other ->
            Nothing


macroSummary : MacroMode -> MacroTotals -> String
macroSummary mode totals =
    case mode of
        Grams ->
            "carbs "
                ++ Number.toFixedOne totals.carbs
                ++ "g ⋅ protein "
                ++ Number.toFixedOne totals.protein
                ++ "g ⋅ fat "
                ++ Number.toFixedOne totals.fat
                ++ "g"

        Percent ->
            "carbs "
                ++ String.fromInt (round totals.carbsPct)
                ++ "% ⋅ protein "
                ++ String.fromInt (round totals.proteinPct)
                ++ "% ⋅ fat "
                ++ String.fromInt (round totals.fatPct)
                ++ "%"


logRow : Theme -> FoodLog -> Element Msg
logRow theme log =
    Input.button
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        ]
        { onPress = Just (LogClicked log.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                [ View.Nutrients.macroDot theme log.nutrients
                , Element.el
                    [ Element.width Element.fill
                    , Element.htmlAttribute (Html.Attributes.style "min-width" "0")
                    ]
                    (Typography.wrappedListItemTitle theme log.item.name)
                , Element.row
                    [ Element.alignRight, Element.spacing DesignTokens.space12 ]
                    [ Typography.mutedCaption theme
                        (log.quantity.amount ++ " " ++ log.quantity.unit)
                    , Typography.mutedCaption theme
                        (String.fromInt (round (Nutrition.caloriesFrom log.nutrients)) ++ " kcal")
                    ]
                ]
        }
