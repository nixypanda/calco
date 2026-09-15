module Page.Diary.Day exposing
    ( CopyRefresh(..)
    , CopyState(..)
    , DiaryState(..)
    , LatestSlotSource
    , LatestSlotsState(..)
    , LoadedState
    , LoadingState
    , MacroMode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , asMain
    , contentView
    , currentLogs
    , init
    , slotCalories
    , update
    )

import Api.Client as Client
import Api.Logs exposing (BatchLogResponse, CreateLogRequest, LatestSlotsResponse)
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
import Ui.Button as Button
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Icon as Icon
import Ui.Surface as Surface
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


asMain : Model -> Model
asMain model =
    { model | calendarMonth = Nothing }


{-| Only the loaded state carries a date: suggestions must not be rendered
against a day other than the one they were requested for, and the user can page
between days faster than the request completes.
-}
type LatestSlotsState
    = LatestSlotsLoading
    | LatestSlotsLoaded LocalDate (List LatestSlotSource)
    | LatestSlotsFailed


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
    { date : LocalDate
    , calendarMonth : Maybe String
    , today : LocalDate
    }
    -> ( Model, OutMsg )
init args =
    ( { currentDate = args.date
      , today = args.today
      , calendarMonth = args.calendarMonth
      , diary = loadingState args.date
      , latestSlots = LatestSlotsLoading
      , copyState = CopyIdle
      , macroMode = Grams
      , preferences = Nothing
      }
    , RequestDiaryData
    )


{-| A pane part-way through a reload still holds the logs it was showing
before, which is why this is not simply the `Loaded` case.
-}
currentLogs : Model -> Maybe (List FoodLog)
currentLogs model =
    case model.diary of
        Loaded loaded ->
            Just loaded.logs

        Loading loading ->
            loading.logs

        Failed _ _ ->
            Nothing



-- UPDATE


type Msg
    = SlotNoOp
    | LogsLoaded LocalDate (Result Client.ApiError (List FoodLog))
    | GoalLoaded LocalDate (Result Client.ApiError GoalSnapshot)
    | PreferencesLoaded (Result Client.ApiError DiaryPreferences)
    | LatestSlotsReceived LocalDate (Result Client.ApiError LatestSlotsResponse)
    | CopyLatestClicked LatestSlotSource
    | CopyLatestCompleted LocalDate (Result Client.ApiError BatchLogResponse)
    | PreviousDayClicked
    | NextDayClicked
    | DetailsClicked
    | MacroModeToggled
    | AddFoodClicked MealSlot
    | LogClicked String
    | MealsClicked
    | TodayChanged LocalDate


type OutMsg
    = NoOp
    | RequestDiaryData
    | RequestCopyLatestSlot LocalDate (List CreateLogRequest)
    | LogsCopied LocalDate CopyRefresh
    | Navigate Route
    | SessionExpired


type CopyRefresh
    = DiaryUpdated
    | DiaryNeedsReload


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        SlotNoOp ->
            ( model, Cmd.none, NoOp )

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

        LatestSlotsReceived requestDate result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok response ->
                        ( { model
                            | latestSlots =
                                LatestSlotsLoaded
                                    requestDate
                                    (latestSlotSources response)
                          }
                        , Cmd.none
                        , NoOp
                        )

                    Err error ->
                        if Client.isUnauthorized error then
                            ( model, Cmd.none, SessionExpired )

                        else
                            ( { model | latestSlots = LatestSlotsFailed }
                            , Cmd.none
                            , NoOp
                            )

        CopyLatestClicked source ->
            ( { model | copyState = Copying source.slot }
            , Cmd.none
            , source.logs
                |> List.filterMap (copyRequestFromLog model.currentDate source.slot)
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
                                , LogsCopied requestDate DiaryUpdated
                                )

                            Nothing ->
                                ( { model
                                    | copyState = CopyIdle
                                    , diary = loadingState requestDate
                                    , latestSlots = LatestSlotsLoading
                                  }
                                , Cmd.none
                                , LogsCopied requestDate DiaryNeedsReload
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
            ( model
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
                    ( model
                    , Cmd.none
                    , Navigate
                        (DiaryDay
                            (Just (LocalDate.format next))
                            model.calendarMonth
                        )
                    )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        DetailsClicked ->
            ( model
            , Cmd.none
            , Navigate (NutritionDetails (Just (LocalDate.format model.currentDate)))
            )

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
            , Navigate
                (FoodLogEntry
                    id
                    (Just (LocalDate.format model.currentDate))
                    model.calendarMonth
                )
            )

        MealsClicked ->
            ( model, Cmd.none, Navigate MealList )

        TodayChanged today ->
            ( { model | today = today }, Cmd.none, NoOp )


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


latestSlotSources : LatestSlotsResponse -> List LatestSlotSource
latestSlotSources response =
    response.slots
        |> List.filterMap
            (\slot ->
                MealSlot.fromString slot.mealSlot
                    |> Maybe.map
                        (\parsed ->
                            { slot = parsed
                            , sourceDate = slot.sourceDate
                            , logs = slot.items
                            }
                        )
            )


removeLatestSlotSource : LocalDate -> Maybe MealSlot -> LatestSlotsState -> LatestSlotsState
removeLatestSlotSource requestDate maybeSlot state =
    case ( maybeSlot, state ) of
        ( Just slot, LatestSlotsLoaded date sources ) ->
            if LocalDate.equals date requestDate then
                LatestSlotsLoaded date (removeSource slot sources)

            else
                state

        _ ->
            state


removeSource : MealSlot -> List LatestSlotSource -> List LatestSlotSource
removeSource slot sources =
    List.filter (\source -> source.slot /= slot) sources


latestSlotSourceFor : LocalDate -> MealSlot -> LatestSlotsState -> Maybe LatestSlotSource
latestSlotSourceFor currentDate slot state =
    case state of
        LatestSlotsLoaded date sources ->
            if LocalDate.equals date currentDate then
                sources
                    |> List.filter (\source -> source.slot == slot)
                    |> List.head

            else
                Nothing

        _ ->
            Nothing


copyRequestFromLog : LocalDate -> MealSlot -> FoodLog -> Maybe CreateLogRequest
copyRequestFromLog targetDate slot log =
    FoodLog.itemRef log.item
        |> Maybe.map
            (\item ->
                { logDate = targetDate
                , deviceTimezone = log.deviceTimezone
                , mealSlot = Just (MealSlot.toString slot)
                , item = item
                , quantity = log.quantity
                , notes = log.notes
                }
            )


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
        |> FoodLog.logsForSlot (Just slot)
        |> List.map (.nutrients >> Nutrition.caloriesFrom)
        |> List.sum



-- VIEW


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView { model, device, theme } =
    let
        logs : List FoodLog
        logs =
            diaryLogs model.currentDate model.diary
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        (dateCard theme model device
            :: (case activeDiaryError model.currentDate model.diary of
                    Just message ->
                        [ Feedback.errorBanner theme message ]

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
    Surface.card theme
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Button.iconButton device
                theme
                { icon = Icon.ChevronLeft
                , title = "Previous Day"
                , onPress = Just PreviousDayClicked
                , tone = Button.Primary
                }
            , Element.el
                [ Element.width Element.fill
                , Font.center
                ]
                (Typography.sectionTitle theme (LocalDate.display model.currentDate))
            , if canGoNext then
                Button.iconButton device
                    theme
                    { icon = Icon.ChevronRight
                    , title = "Next Day"
                    , onPress = Just NextDayClicked
                    , tone = Button.Primary
                    }

              else
                Button.iconButton device
                    theme
                    { icon = Icon.ChevronRight
                    , title = ""
                    , onPress = Nothing
                    , tone = Button.Primary
                    }
            ]
        , Surface.hairline theme
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = DesignTokens.space8, right = 0, bottom = 0, left = 0 }
            ]
            [ case loadedGoalTargets model.currentDate model.diary of
                Just targets ->
                    totalsView device theme targets (Nutrition.totalsFromLogs logs)

                Nothing ->
                    totalsView device theme loadingGoalTargets (Nutrition.totalsFromLogs logs)
            ]
        ]


totalsView : Device -> Theme -> GoalTargets -> List NutrientAmount -> Element Msg
totalsView device theme targets summary =
    let
        calories : Float
        calories =
            Nutrition.caloriesFrom summary
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ calorieHero theme calories targets.calorieTarget
        , Surface.hairline theme
        , macroSummaryRow theme
            [ { label = "Protein"
              , value = summaryAmount "PROTEIN_G" summary
              , color = theme.proteinAccent
              , target = targets.proteinTargetG
              , tolerance = macroTolerance targets.proteinTargetG
              }
            , { label = "Carbs"
              , value = summaryAmount "CARBS_G" summary
              , color = theme.carbsAccent
              , target = targets.carbsTargetG
              , tolerance = macroTolerance targets.carbsTargetG
              }
            , { label = "Fat"
              , value = summaryAmount "FAT_G" summary
              , color = theme.fatAccent
              , target = targets.fatTargetG
              , tolerance = macroTolerance targets.fatTargetG
              }
            ]
        , detailsAction device theme
        ]


detailsAction : Device -> Theme -> Element Msg
detailsAction device theme =
    Button.textButton device
        theme
        { tone = Button.GhostFilled
        , width = Button.FullWidth
        , label = "Details"
        , onPress = DetailsClicked
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing =
            Just
                (Icon.view
                    { icon = Icon.ChevronRight
                    , size = 18
                    , color = theme.brandBlue
                    }
                )
        }


calorieHero : Theme -> Float -> Float -> Element msg
calorieHero theme calories target =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space12
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            , Element.centerY
            ]
            [ Element.column
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space2
                ]
                [ Element.el
                    [ Font.bold
                    , Font.color theme.textMedium
                    , Typography.caption
                    ]
                    (Element.text "CALORIES")
                , Typography.heroStat theme (formatWhole calories)
                , Element.el
                    [ Typography.body, Font.color theme.textMuted ]
                    (Element.text "kcal eaten")
                ]
            , calorieBalancePill theme target calories
            ]
        , progressBar
            theme
            (if target > 0 && calories > target then
                theme.dangerSolid

             else
                theme.calorieAccent
            )
            DesignTokens.space12
            calories
            target
        , if target > 0 then
            Element.el
                [ Typography.body
                , Font.color theme.textMuted
                , Element.alignRight
                ]
                (Element.text ("of " ++ formatWhole target ++ " kcal"))

          else
            Element.none
        ]


calorieBalancePill : Theme -> Float -> Float -> Element msg
calorieBalancePill theme target calories =
    if target <= 0 then
        Element.none

    else
        let
            difference : Int
            difference =
                round (target - calories)

            statusColor : Element.Color
            statusColor =
                goalScaleColor
                    theme
                    (calorieTolerance target)
                    calories
                    target

            label : String
            label =
                if difference > 0 then
                    formatWhole (toFloat difference) ++ " kcal left"

                else if difference < 0 then
                    formatWhole (toFloat (abs difference)) ++ " kcal over"

                else
                    "Goal met"
        in
        Element.el
            [ Background.color (withAlpha 0.2 statusColor)
            , Font.color statusColor
            , Border.rounded DesignTokens.radiusPill
            , Element.paddingXY DesignTokens.space16 DesignTokens.space12
            , Typography.body
            , Font.bold
            , Element.alignRight
            ]
            (Element.text label)


type alias MacroSummary =
    { label : String
    , value : Float
    , color : Element.Color
    , target : Float
    , tolerance : Float
    }


macroSummaryRow : Theme -> List MacroSummary -> Element msg
macroSummaryRow theme macros =
    let
        divider : Element msg
        divider =
            Element.el
                [ Element.width (Element.px 1)
                , Element.height Element.fill
                , Background.color theme.divider
                ]
                Element.none
    in
    macros
        |> List.map (macroSummaryItem theme)
        |> List.intersperse divider
        |> Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space8
            ]


macroSummaryItem : Theme -> MacroSummary -> Element msg
macroSummaryItem theme macro =
    Element.column
        [ Element.width (Element.fillPortion 1)
        , Element.spacing DesignTokens.space8
        ]
        [ Element.el
            [ Font.bold
            , Font.color theme.textPrimary
            , Typography.body
            ]
            (Element.text macro.label)
        , Element.el
            ([ Font.bold
             , Typography.body
             ]
                ++ (if macro.target > 0 then
                        [ Font.color
                            (goalScaleColor
                                theme
                                macro.tolerance
                                macro.value
                                macro.target
                            )
                        ]

                    else
                        [ Font.color theme.textMuted ]
                   )
            )
            (Element.text (macroAmountLabel macro))
        , progressBar
            theme
            macro.color
            DesignTokens.space8
            macro.value
            macro.target
        ]


macroAmountLabel : MacroSummary -> String
macroAmountLabel macro =
    if macro.target > 0 then
        formatWhole macro.value ++ " / " ++ formatWhole macro.target ++ " g"

    else
        formatWhole macro.value ++ " g"


progressBar : Theme -> Element.Color -> Int -> Float -> Float -> Element msg
progressBar theme color height value target =
    let
        filled : Int
        filled =
            if target > 0 then
                value
                    / target
                    |> clamp 0 1
                    |> (*) 100
                    |> round

            else
                0

        remaining : Int
        remaining =
            100 - filled
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px height)
        , Background.color theme.inputFill
        , Border.rounded DesignTokens.radiusPill
        , Element.clip
        ]
        [ Element.el
            [ Element.width (Element.fillPortion filled)
            , Element.height Element.fill
            , Background.color color
            , Border.rounded DesignTokens.radiusPill
            ]
            Element.none
        , Element.el [ Element.width (Element.fillPortion remaining) ] Element.none
        ]


goalScaleColor : Theme -> Float -> Float -> Float -> Element.Color
goalScaleColor theme tolerance value target =
    let
        lowerBound : Float
        lowerBound =
            max 0 (target - tolerance)

        upperBound : Float
        upperBound =
            target + tolerance

        underProgress : Float
        underProgress =
            if lowerBound > 0 then
                clamp 0 1 (value / lowerBound)

            else
                1

        overProgress : Float
        overProgress =
            clamp 0 1 ((value - upperBound) / tolerance)
    in
    if value < lowerBound then
        mixColor (goalUnderColor theme) theme.statusGreen underProgress

    else if value <= upperBound then
        theme.statusGreen

    else
        mixColor
            theme.statusGreen
            theme.dangerFg
            overProgress


calorieTolerance : Float -> Float
calorieTolerance target =
    clamp 30 75 (target * 0.025)


macroTolerance : Float -> Float
macroTolerance target =
    max 2 (target * 0.05)


goalUnderColor : Theme -> Element.Color
goalUnderColor theme =
    case theme.mode of
        Light ->
            Element.rgb255 0 135 145

        Dark ->
            theme.calorieAccent


mixColor : Element.Color -> Element.Color -> Float -> Element.Color
mixColor from to amount =
    let
        start : { red : Float, green : Float, blue : Float, alpha : Float }
        start =
            Element.toRgb from

        finish : { red : Float, green : Float, blue : Float, alpha : Float }
        finish =
            Element.toRgb to

        mix : Float -> Float -> Float
        mix a b =
            a + (b - a) * amount
    in
    Element.rgba
        (mix start.red finish.red)
        (mix start.green finish.green)
        (mix start.blue finish.blue)
        (mix start.alpha finish.alpha)


withAlpha : Float -> Element.Color -> Element.Color
withAlpha alpha color =
    let
        rgb : { red : Float, green : Float, blue : Float, alpha : Float }
        rgb =
            Element.toRgb color
    in
    Element.rgba rgb.red rgb.green rgb.blue alpha


formatWhole : Float -> String
formatWhole value =
    let
        number : Int
        number =
            round value

        digits : String
        digits =
            String.fromInt (abs number)

        sign : String
        sign =
            if number < 0 then
                "-"

            else
                ""
    in
    sign ++ groupThousands digits


groupThousands : String -> String
groupThousands digits =
    if String.length digits <= 3 then
        digits

    else
        let
            splitAt : Int
            splitAt =
                String.length digits - 3
        in
        groupThousands (String.left splitAt digits)
            ++ ","
            ++ String.dropLeft splitAt digits


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
            [ Feedback.errorBanner theme message ]

        _ ->
            []


type alias SlotSection =
    { slot : Maybe MealSlot
    , logs : List FoodLog
    }


logGroupsView : Theme -> Device -> Model -> List FoodLog -> Element Msg
logGroupsView theme device model logs =
    let
        section : Maybe MealSlot -> SlotSection
        section slot =
            { slot = slot, logs = FoodLog.logsForSlot slot logs }

        unslotted : SlotSection
        unslotted =
            section Nothing
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        ((MealSlot.all
            |> List.map (Just >> section)
            |> List.filter (shouldShowSection model.preferences)
         )
            ++ (if List.isEmpty unslotted.logs then
                    []

                else
                    [ unslotted ]
               )
            |> List.map (slotView theme device model)
        )


shouldShowSection : Maybe DiaryPreferences -> SlotSection -> Bool
shouldShowSection maybePreferences section =
    not (List.isEmpty section.logs)
        || (Maybe.map2 DiaryPreferences.isEnabled section.slot maybePreferences
                |> Maybe.withDefault False
           )


slotView : Theme -> Device -> Model -> SlotSection -> Element Msg
slotView theme device model section =
    let
        totals : MacroTotals
        totals =
            Nutrition.macroTotals section.logs

        body : List (Element Msg)
        body =
            case section.slot of
                Just slot ->
                    (if List.isEmpty section.logs then
                        [ emptySlotView theme device model slot ]

                     else
                        List.map (logRow theme) section.logs
                    )
                        ++ [ Surface.hairline theme
                           , Button.textButton device
                                theme
                                { tone = Button.Ghost
                                , width = Button.FullWidth
                                , label = "+ Add Food"
                                , onPress = AddFoodClicked slot
                                , submitState = Nothing
                                , submittingLabel = Nothing
                                , trailing = Nothing
                                }
                           ]

                Nothing ->
                    List.map (logRow theme) section.logs
    in
    mealSlotCard theme
        device
        section.slot
        (mealSlotHeader theme model.macroMode section totals)
        (Surface.hairline theme :: body)


emptySlotView : Theme -> Device -> Model -> MealSlot -> Element Msg
emptySlotView theme device model slot =
    case latestSlotSourceFor model.currentDate slot model.latestSlots of
        Just source ->
            let
                isLogging : Bool
                isLogging =
                    case model.copyState of
                        Copying copyingSlot ->
                            copyingSlot == source.slot

                        _ ->
                            False
            in
            emptySlotBody
                (Button.textButton device
                    theme
                    { tone = Button.Ghost
                    , width = Button.FullWidth
                    , label = logLatestLabel source
                    , onPress = CopyLatestClicked source
                    , submitState = Just (Button.submittingOrIdle isLogging)
                    , submittingLabel = Just "Logging..."
                    , trailing = Nothing
                    }
                )

        Nothing ->
            emptySlotBody
                (Button.textButton device
                    theme
                    { tone = Button.Ghost
                    , width = Button.FullWidth
                    , label = "No items"
                    , onPress = SlotNoOp
                    , submitState = Just Button.Disabled
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )


emptySlotBody : Element Msg -> Element Msg
emptySlotBody content =
    Element.el
        [ Element.width Element.fill
        , Element.padding DesignTokens.space12
        ]
        content


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
            [ Typography.sectionTitle theme (sectionTitle section.slot)
            , Input.button []
                { onPress = Just MacroModeToggled
                , label = Typography.mutedCaption theme (macroSummary macroMode totals)
                }
            ]
        , Typography.mutedCaption theme
            (String.fromInt (round sectionKcal) ++ " kcal")
        ]


sectionTitle : Maybe MealSlot -> String
sectionTitle maybeSlot =
    case maybeSlot of
        Just slot ->
            MealSlot.label slot

        Nothing ->
            "Other"


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
                        ++ UiCommon.toCssColor theme.cardBg
                        ++ " 100%)"

                Dark ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(0,0,0,0.25) 0%, "
                        ++ "rgba(0,0,0,0.55) 45%, "
                        ++ "rgba(0,0,0,0.85) 75%, "
                        ++ UiCommon.toCssColor theme.cardBg
                        ++ " 100%)"
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.htmlAttribute (Html.Attributes.style "background-image" gradient)
        ]
        Element.none


mealSlotCard :
    Theme
    -> Device
    -> Maybe MealSlot
    -> Element Msg
    -> List (Element Msg)
    -> Element Msg
mealSlotCard theme device maybeSlot header bodyChildren =
    case maybeSlot of
        Nothing ->
            Surface.card theme (header :: bodyChildren)

        Just slot ->
            Surface.heroCard theme
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
    if UiCommon.isSmall device then
        16

    else
        34


mealSlotBackground : MealSlot -> List (Element.Attribute msg)
mealSlotBackground slot =
    let
        image : { url : String, focusX : String }
        image =
            mealSlotImage slot
    in
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


mealSlotImage : MealSlot -> { url : String, focusX : String }
mealSlotImage slot =
    case slot of
        Breakfast ->
            { url = "/assets/breakfast.png", focusX = "13%" }

        Lunch ->
            { url = "/assets/lunch.png", focusX = "50%" }

        Dinner ->
            { url = "/assets/dinner.png", focusX = "47%" }

        Snack ->
            { url = "/assets/snacks.png", focusX = "82%" }

        LateNightSnack ->
            { url = "/assets/late-night-snack.png", focusX = "73%" }


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
                    (Typography.wrappedListItemTitle theme (FoodLog.itemName log.item))
                , Element.row
                    [ Element.alignRight, Element.spacing DesignTokens.space12 ]
                    [ Typography.mutedCaption theme
                        (log.quantity.amount ++ " " ++ log.quantity.unit)
                    , Typography.mutedCaption theme
                        (String.fromInt (round (Nutrition.caloriesFrom log.nutrients)) ++ " kcal")
                    ]
                ]
        }
