module Page.Diary.Index exposing
    ( DiaryState(..)
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
import Api.Result as ApiResult
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition exposing (MacroTotals, NutrientAmount)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Lib.Date as LocalDate exposing (LocalDate)
import Ui


type MacroMode
    = Grams
    | Percent


type DiaryState
    = Loading LocalDate
    | Loaded LocalDate (List FoodLog)
    | Failed LocalDate String


type alias Model =
    { currentDate : LocalDate
    , today : LocalDate
    , diary : DiaryState
    , macroMode : MacroMode
    }


type Msg
    = LoadStarted
    | LogsLoaded LocalDate (Result Client.ApiError (List FoodLog))
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
      , diary = Loading currentDate
      , macroMode = Grams
      }
    , RequestDiaryData currentDate
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LoadStarted ->
            case model.diary of
                Loading date ->
                    if LocalDate.equals date model.currentDate then
                        ( model, Cmd.none, NoOp )

                    else
                        ( { model | diary = Loading model.currentDate }, Cmd.none, NoOp )

                _ ->
                    ( { model | diary = Loading model.currentDate }, Cmd.none, NoOp )

        LogsLoaded requestDate result ->
            if not (LocalDate.equals requestDate model.currentDate) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok logs ->
                        ( { model | diary = Loaded requestDate (logsForDate requestDate logs) }
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
            ( { model | currentDate = previous, diary = Loading previous }
            , Cmd.none
            , Navigate (Diary (Just (LocalDate.format previous)))
            )

        NextDayClicked ->
            case LocalDate.nextOnOrBefore model.today model.currentDate of
                Just next ->
                    ( { model | currentDate = next, diary = Loading next }
                    , Cmd.none
                    , Navigate (Diary (Just (LocalDate.format next)))
                    )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        MacroModeToggled ->
            ( { model | macroMode = toggleMacroMode model.macroMode }, Cmd.none, NoOp )

        AddFoodClicked slot ->
            ( model, Cmd.none, Navigate (FoodSearch (Just slot)) )

        LogClicked id ->
            ( model, Cmd.none, Navigate (FoodLogDetail id) )

        MealsClicked ->
            ( model, Cmd.none, Navigate Meals )


failure : LocalDate -> Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure requestDate =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | diary = Failed requestDate message }
        }


logsForDate : LocalDate -> List FoodLog -> List FoodLog
logsForDate date logs =
    List.filter (\log -> LocalDate.equals log.logDate date) logs


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


dailyCalories : List NutrientAmount -> Float
dailyCalories summary =
    Nutrition.nutrientAmount "ENERGY_KCAL" summary


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (dateCard model
            :: (case model.diary of
                    Loading _ ->
                        [ Ui.skeletonLoading ]

                    Loaded date logs ->
                        if LocalDate.equals date model.currentDate then
                            [ logGroupsView model logs ]

                        else
                            [ Ui.skeletonLoading ]

                    Failed date message ->
                        if LocalDate.equals date model.currentDate then
                            [ Ui.errorBanner message ]

                        else
                            [ Ui.skeletonLoading ]
               )
        )


dateCard : Model -> Element Msg
dateCard model =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare model.currentDate model.today == LT
    in
    Ui.card
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing 12
            ]
            [ Ui.smallButton "Previous" PreviousDayClicked
            , Element.el
                [ Element.width Element.fill
                , Font.center
                , Font.bold
                ]
                (Element.text (LocalDate.display model.currentDate))
            , Input.button
                [ Background.color
                    (if canGoNext then
                        Ui.primaryTeal

                     else
                        Ui.borderGray
                    )
                , Font.color
                    (if canGoNext then
                        Element.rgb255 255 255 255

                     else
                        Ui.mutedColor
                    )
                , Border.rounded 6
                , Element.paddingXY 12 8
                , Ui.caption
                ]
                { onPress =
                    if canGoNext then
                        Just NextDayClicked

                    else
                        Nothing
                , label = Element.text "Next"
                }
            ]
        , totalsView (Nutrition.totalsFromLogs (loadedLogs model.currentDate model.diary))
        ]


totalsView : List NutrientAmount -> Element Msg
totalsView summary =
    Element.column [ Element.width Element.fill, Element.spacing 8 ]
        [ Ui.macroBar
            { label = "Calories"
            , value = dailyCalories summary
            , unit = "kcal"
            , color = Ui.primaryTeal
            , max = diaryDefaults.calorieGoal
            }
        , Ui.macroBar
            { label = "Protein"
            , value = summaryAmount "PROTEIN_G" summary
            , unit = "g"
            , color = Ui.proteinColor
            , max = diaryDefaults.proteinGoal
            }
        , Ui.macroBar
            { label = "Carbs"
            , value = summaryAmount "CARBS_G" summary
            , unit = "g"
            , color = Ui.carbsColor
            , max = diaryDefaults.carbsGoal
            }
        , Ui.macroBar
            { label = "Fat"
            , value = summaryAmount "FAT_G" summary
            , unit = "g"
            , color = Ui.fatColor
            , max = diaryDefaults.fatGoal
            }
        ]


summaryAmount : String -> List NutrientAmount -> Float
summaryAmount code summary =
    Nutrition.summaryValue code summary
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


diaryDefaults :
    { calorieGoal : Float
    , proteinGoal : Float
    , carbsGoal : Float
    , fatGoal : Float
    }
diaryDefaults =
    { calorieGoal = 2000
    , proteinGoal = 150
    , carbsGoal = 250
    , fatGoal = 65
    }


loadedLogs : LocalDate -> DiaryState -> List FoodLog
loadedLogs currentDate diary =
    case diary of
        Loaded loadedDate logs ->
            if LocalDate.equals loadedDate currentDate then
                logs

            else
                []

        _ ->
            []


logGroupsView : Model -> List FoodLog -> Element Msg
logGroupsView model logs =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ slotView model logs Breakfast (MealSlot.label Breakfast)
        , slotView model logs Lunch (MealSlot.label Lunch)
        , slotView model logs Dinner (MealSlot.label Dinner)
        , slotView model logs Snack (MealSlot.label Snack)
        , let
            otherLogs : List FoodLog
            otherLogs =
                FoodLog.logsForSlot Other logs
          in
          if List.isEmpty otherLogs then
            Element.none

          else
            slotView model logs Other (MealSlot.label Other)
        ]


slotView : Model -> List FoodLog -> MealSlot -> String -> Element Msg
slotView model allLogs slot label =
    let
        logs : List FoodLog
        logs =
            FoodLog.logsForSlot slot allLogs

        totals : MacroTotals
        totals =
            Nutrition.macroTotals logs
    in
    Ui.card
        (Element.row [ Element.width Element.fill, Element.padding 14, Element.spacing 12 ]
            [ Element.column [ Element.width Element.fill, Element.spacing 4 ]
                [ Element.el [ Font.bold ] (Element.text label)
                , Input.button [ Font.color Ui.mutedColor, Ui.caption ]
                    { onPress = Just MacroModeToggled
                    , label = Element.text (macroSummary model.macroMode totals)
                    }
                ]
            , Element.el
                [ Ui.caption
                , Font.color Ui.mutedColor
                ]
                (Element.text (String.fromInt (round (slotCalories slot allLogs)) ++ " kcal"))
            ]
            :: ((if List.isEmpty logs then
                    [ Element.el
                        [ Element.padding 14
                        , Font.color Ui.mutedColor
                        , Element.centerX
                        ]
                        (Element.text "No items")
                    ]

                 else
                    List.map logRow logs
                )
                    ++ (case slot of
                            Other ->
                                []

                            _ ->
                                [ Input.button
                                    [ Element.width Element.fill
                                    , Element.padding 12
                                    , Border.widthEach { top = 1, right = 0, bottom = 0, left = 0 }
                                    , Border.color Ui.borderGray
                                    , Font.color Ui.primaryTeal
                                    , Font.medium
                                    ]
                                    { onPress = Just (AddFoodClicked slot)
                                    , label = Element.text "Add Food"
                                    }
                                ]
                       )
               )
        )


macroSummary : MacroMode -> MacroTotals -> String
macroSummary mode totals =
    case mode of
        Grams ->
            "carbs "
                ++ Nutrition.oneDecimal totals.carbs
                ++ "g ⋅ protein "
                ++ Nutrition.oneDecimal totals.protein
                ++ "g ⋅ fat "
                ++ Nutrition.oneDecimal totals.fat
                ++ "g"

        Percent ->
            "carbs "
                ++ String.fromInt (round totals.carbsPct)
                ++ "% ⋅ protein "
                ++ String.fromInt (round totals.proteinPct)
                ++ "% ⋅ fat "
                ++ String.fromInt (round totals.fatPct)
                ++ "%"


logRow : FoodLog -> Element Msg
logRow log =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 1, right = 0, bottom = 0, left = 0 }
        , Border.color Ui.borderGray
        ]
        { onPress = Just (LogClicked log.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.el
                    [ Element.width Element.fill
                    , Font.medium
                    ]
                    (Element.text log.item.name)
                , Element.el
                    [ Ui.caption
                    , Font.color Ui.mutedColor
                    ]
                    (Element.text (log.quantity.amount ++ " " ++ log.quantity.unit))
                , Element.el
                    [ Ui.caption
                    , Font.color Ui.mutedColor
                    ]
                    (Element.text
                        (String.fromInt
                            (round (Nutrition.caloriesFrom log.nutrients))
                            ++ " kcal"
                        )
                    )
                ]
        }
