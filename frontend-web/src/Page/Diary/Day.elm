module Page.Diary.Day exposing
    ( DiaryState(..)
    , LoadedState
    , LoadingState
    , MacroMode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , dailyCalories
    , init
    , slotCalories
    , update
    , view
    )

import Api.Client as Client
import Data.FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalTargets)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition exposing (MacroTotals, NutrientAmount)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Ui
import Ui.Theme exposing (Mode(..), Theme)
import View.Nutrients


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
    , diary : DiaryState
    , macroMode : MacroMode
    }


type Msg
    = LoadStarted
    | LogsLoaded LocalDate (Result Client.ApiError (List FoodLog))
    | GoalLoaded LocalDate (Result Client.ApiError GoalSnapshot)
    | PreviousDayClicked
    | NextDayClicked
    | MacroModeToggled
    | AddFoodClicked MealSlot
    | LogClicked String
    | MealsClicked


type OutMsg
    = NoOp
    | RequestDiaryData LocalDate
    | Navigate Route
    | SessionExpired


init : { dateParam : Maybe String, today : LocalDate } -> ( Model, OutMsg )
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
      , diary = loadingState currentDate
      , macroMode = Grams
      }
    , RequestDiaryData currentDate
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LoadStarted ->
            case model.diary of
                Loading loading ->
                    if LocalDate.equals loading.date model.currentDate then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | diary = loadingState model.currentDate }, Cmd.none, NoOp )

                _ ->
                    ( { model | diary = loadingState model.currentDate }, Cmd.none, NoOp )

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

        PreviousDayClicked ->
            let
                previous : LocalDate
                previous =
                    LocalDate.addDays -1 model.currentDate
            in
            ( { model | currentDate = previous, diary = loadingState previous }
            , Cmd.none
            , Navigate (DiaryDay (Just (LocalDate.format previous)))
            )

        NextDayClicked ->
            case LocalDate.nextOnOrBefore model.today model.currentDate of
                Just next ->
                    ( { model | currentDate = next, diary = loadingState next }
                    , Cmd.none
                    , Navigate (DiaryDay (Just (LocalDate.format next)))
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
            ( model, Cmd.none, Navigate (FoodLogEntry id) )

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


applyLogsLoaded : LocalDate -> List FoodLog -> DiaryState -> DiaryState
applyLogsLoaded requestDate logs diary =
    let
        filteredLogs : List FoodLog
        filteredLogs =
            logsForDate requestDate logs
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


logsForDate : LocalDate -> List FoodLog -> List FoodLog
logsForDate date logs =
    List.filter (\log -> LocalDate.equals log.logDate date) logs


logsForSlot : MealSlot -> List FoodLog -> List FoodLog
logsForSlot slot logs =
    List.filter (\log -> MealSlot.matches slot log.mealSlot) logs


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
        |> logsForSlot slot
        |> List.map (.nutrients >> caloriesFrom)
        |> List.sum


caloriesFrom : List NutrientAmount -> Float
caloriesFrom nutrients =
    Nutrition.nutrientAmount "ENERGY_KCAL" nutrients


totalsFromLogs : List { log | nutrients : List NutrientAmount } -> List NutrientAmount
totalsFromLogs logs =
    let
        allNutrients : List NutrientAmount
        allNutrients =
            logs
                |> List.concatMap .nutrients

        codes : List String
        codes =
            allNutrients
                |> List.map .code
                |> uniqueCodes

        units : List { code : String, unit : String }
        units =
            allNutrients
                |> List.map (\n -> { code = n.code, unit = n.unit })
                |> uniqueBy .code

        unitForCode : String -> String
        unitForCode code =
            List.filter (.code >> (==) code) units
                |> List.head
                |> Maybe.map .unit
                |> Maybe.withDefault ""
    in
    codes
        |> List.map
            (\code ->
                { code = code
                , amount =
                    allNutrients
                        |> List.filter (.code >> (==) code)
                        |> List.map (.amount >> Nutrition.safeAmount)
                        |> List.sum
                        |> String.fromFloat
                , unit = unitForCode code
                }
            )


uniqueCodes : List String -> List String
uniqueCodes list =
    List.foldr
        (\code acc ->
            if List.member code acc then
                acc

            else
                code :: acc
        )
        []
        list


uniqueBy : (a -> comparable) -> List a -> List a
uniqueBy toKey list =
    List.foldr
        (\item acc ->
            if List.member (toKey item) (List.map toKey acc) then
                acc

            else
                item :: acc
        )
        []
        list


dailyCalories : List NutrientAmount -> Float
dailyCalories summary =
    caloriesFrom summary


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
                        [ logGroupsView theme device model logs ]
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
            , Element.spacing Ui.space12
            ]
            [ Ui.iconButton device
                theme
                { label = "←", title = "Previous Day", onPress = PreviousDayClicked }
            , Element.el
                [ Element.width Element.fill
                , Font.center
                ]
                (Ui.sectionTitle theme device (LocalDate.display model.currentDate))
            , if canGoNext then
                Ui.iconButton device
                    theme
                    { label = "→", title = "Next Day", onPress = NextDayClicked }

              else
                Ui.disabledIconButton theme { label = "→" }
            ]
        , Ui.hairline theme
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = Ui.space8, right = 0, bottom = 0, left = 0 }
            ]
            [ case loadedGoalTargets model.currentDate model.diary of
                Just targets ->
                    totalsView theme targets (totalsFromLogs logs)

                Nothing ->
                    totalsView theme loadingGoalTargets (totalsFromLogs logs)
            ]
        ]


totalsView : Theme -> GoalTargets -> List NutrientAmount -> Element Msg
totalsView theme targets summary =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space16 ]
        [ Ui.macroBar theme
            { label = "Calories"
            , value = dailyCalories summary
            , unit = "kcal"
            , color = Ui.primaryTeal
            , max = targets.calorieTarget
            }
        , Ui.macroBar theme
            { label = "Protein"
            , value = summaryAmount "PROTEIN_G" summary
            , unit = "g"
            , color = Ui.proteinColor
            , max = targets.proteinTargetG
            }
        , Ui.macroBar theme
            { label = "Carbs"
            , value = summaryAmount "CARBS_G" summary
            , unit = "g"
            , color = Ui.carbsColor
            , max = targets.carbsTargetG
            }
        , Ui.macroBar theme
            { label = "Fat"
            , value = summaryAmount "FAT_G" summary
            , unit = "g"
            , color = Ui.fatColor
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


type alias SlotSection =
    { slot : MealSlot
    , logs : List FoodLog
    }


logGroupsView : Theme -> Device -> Model -> List FoodLog -> Element Msg
logGroupsView theme device model logs =
    let
        section : MealSlot -> SlotSection
        section slot =
            { slot = slot, logs = logsForSlot slot logs }

        otherSection : SlotSection
        otherSection =
            section Other
    in
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ slotView theme device model.macroMode (section Breakfast)
        , slotView theme device model.macroMode (section Lunch)
        , slotView theme device model.macroMode (section Dinner)
        , slotView theme device model.macroMode (section Snack)
        , if List.isEmpty otherSection.logs then
            Element.none

          else
            slotView theme device model.macroMode otherSection
        ]


slotView : Theme -> Device -> MacroMode -> SlotSection -> Element Msg
slotView theme device macroMode section =
    let
        totals : MacroTotals
        totals =
            Nutrition.macroTotals section.logs
    in
    mealSlotCard theme
        device
        section.slot
        (mealSlotHeader theme device macroMode section totals)
        (Ui.hairline theme
            :: (if List.isEmpty section.logs then
                    [ Element.el
                        [ Element.padding Ui.space12
                        , Font.color theme.textMuted
                        , Element.centerX
                        ]
                        (Element.text "No items")
                    ]

                else
                    List.map (logRow theme device) section.logs
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


mealSlotHeader :
    Theme
    -> Device
    -> MacroMode
    -> SlotSection
    -> MacroTotals
    -> Element Msg
mealSlotHeader theme device macroMode section totals =
    let
        sectionKcal : Float
        sectionKcal =
            section.logs
                |> List.map (.nutrients >> caloriesFrom)
                |> List.sum
    in
    Element.row
        [ Element.width Element.fill
        , Element.padding Ui.space12
        , Element.spacing Ui.space12
        ]
        [ Element.column [ Element.width Element.fill, Element.spacing Ui.space4 ]
            [ Ui.sectionTitle theme device (MealSlot.label section.slot)
            , Input.button []
                { onPress = Just MacroModeToggled
                , label = Ui.mutedCaption theme (macroSummary macroMode totals)
                }
            ]
        , Ui.mutedCaption theme
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
                        ++ "rgba(255,255,255,0) 55%, "
                        ++ "rgba(255,255,255,0.48) 85%, "
                        ++ "white 100%)"

                Dark ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(0,0,0,0.25) 0%, "
                        ++ "rgba(0,0,0,0.55) 45%, "
                        ++ "rgba(0,0,0,0.85) 75%, "
                        ++ Ui.toCssColor theme.cardBg
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


logRow : Theme -> Device -> FoodLog -> Element Msg
logRow theme device log =
    Input.button
        [ Element.width Element.fill
        , Element.padding Ui.space12
        ]
        { onPress = Just (LogClicked log.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ View.Nutrients.macroDot log.nutrients
                , Ui.truncatedListItemTitle theme device log.item.name
                , Ui.mutedCaption theme (log.quantity.amount ++ " " ++ log.quantity.unit)
                , Ui.mutedCaption theme
                    (String.fromInt (round (caloriesFrom log.nutrients)) ++ " kcal")
                ]
        }
