module Page.Diary.Index exposing
    ( MacroMode(..)
    , Model
    , Msg(..)
    , OutMsg(..)
    , dailyCalories
    , groupLogs
    , init
    , macroTotals
    , slotCalories
    , update
    , view
    )

import Api.Client as Client
import Api.Result as ApiResult
import Data.FoodLog as FoodLog exposing (FoodLog, GroupedLogs, SummaryResponse)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef exposing (ItemRef)
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


type alias Model =
    { currentDate : LocalDate
    , today : LocalDate
    , logs : List FoodLog
    , summary : List NutrientAmount
    , itemNames : ItemNameLookup.Names
    , loading : Bool
    , error : Maybe String
    , macroMode : MacroMode
    }


type Msg
    = LoadStarted
    | LogsLoaded (Result Client.ApiError (List FoodLog))
    | SummaryLoaded (Result Client.ApiError SummaryResponse)
    | NameLookupCompleted ItemRef (Result Client.ApiError String)
    | PreviousDayClicked
    | NextDayClicked
    | MacroModeToggled
    | AddFoodClicked MealSlot
    | LogClicked String
    | MealsClicked


type OutMsg
    = NoOp
    | RequestDiaryData LocalDate
    | RequestItemNames (List ItemRef)
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
    in
    ( { currentDate = currentDate
      , today = args.today
      , logs = []
      , summary = []
      , itemNames = ItemNameLookup.empty
      , loading = True
      , error = Nothing
      , macroMode = Grams
      }
    , RequestDiaryData currentDate
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LoadStarted ->
            ( { model | loading = True, error = Nothing }, Cmd.none, NoOp )

        LogsLoaded result ->
            case result of
                Ok logs ->
                    ( { model | logs = logs, loading = False, error = Nothing }
                    , Cmd.none
                    , RequestItemNames (uniqueItems logs)
                    )

                Err error ->
                    failure error model

        SummaryLoaded result ->
            case result of
                Ok response ->
                    ( { model | summary = response.totals, loading = False, error = Nothing }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    failure error model

        NameLookupCompleted item result ->
            ( { model
                | itemNames =
                    ItemNameLookup.insertResult item result model.itemNames
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
            ( { model | currentDate = previous, loading = True, error = Nothing }
            , Cmd.none
            , Navigate (Diary (Just (LocalDate.format previous)))
            )

        NextDayClicked ->
            case LocalDate.nextOnOrBefore model.today model.currentDate of
                Just next ->
                    ( { model | currentDate = next, loading = True, error = Nothing }
                    , Cmd.none
                    , Navigate (Diary (Just (LocalDate.format next)))
                    )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        MacroModeToggled ->
            ( { model | macroMode = toggleMacroMode model.macroMode }, Cmd.none, NoOp )

        AddFoodClicked slot ->
            ( model, Cmd.none, Navigate (addFoodRoute slot) )

        LogClicked id ->
            ( model, Cmd.none, Navigate (FoodLogDetail id) )

        MealsClicked ->
            ( model, Cmd.none, Navigate Meals )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | loading = False, error = Just message }
        }


toggleMacroMode : MacroMode -> MacroMode
toggleMacroMode mode =
    case mode of
        Grams ->
            Percent

        Percent ->
            Grams


groupLogs : List FoodLog -> GroupedLogs
groupLogs =
    FoodLog.groupLogs


slotCalories : MealSlot -> List FoodLog -> Float
slotCalories slot logs =
    logs
        |> logsForSlot slot
        |> List.map (.nutrients >> Nutrition.caloriesFrom)
        |> List.sum


dailyCalories : List NutrientAmount -> Float
dailyCalories summary =
    Nutrition.nutrientAmount "ENERGY_KCAL" summary


summaryValue : String -> List NutrientAmount -> Maybe NutrientAmount
summaryValue =
    Nutrition.summaryValue


macroTotals : List FoodLog -> MacroTotals
macroTotals =
    Nutrition.macroTotals


addFoodRoute : MealSlot -> Route
addFoodRoute slot =
    FoodSearch (Just slot)


uniqueItems : List FoodLog -> List ItemRef
uniqueItems =
    ItemRef.unique


logsForSlot : MealSlot -> List FoodLog -> List FoodLog
logsForSlot =
    FoodLog.logsForSlot


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ dateCard model
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , if model.loading then
            Ui.skeletonLoading

          else if List.isEmpty model.logs then
            Ui.emptyState "No food logged for this day."

          else
            logGroupsView model
        ]


dateCard : Model -> Element Msg
dateCard model =
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
                    (if LocalDate.compare model.currentDate model.today == EQ then
                        Ui.borderGray

                     else
                        Ui.primaryTeal
                    )
                , Font.color
                    (if LocalDate.compare model.currentDate model.today == EQ then
                        Ui.mutedColor

                     else
                        Element.rgb255 255 255 255
                    )
                , Border.rounded 6
                , Element.paddingXY 12 8
                , Ui.caption
                ]
                { onPress =
                    if LocalDate.compare model.currentDate model.today == EQ then
                        Nothing

                    else
                        Just NextDayClicked
                , label = Element.text "Next"
                }
            ]
        , totalsView model.summary
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
    summaryValue code summary
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


logGroupsView : Model -> Element Msg
logGroupsView model =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ slotView model Breakfast (MealSlot.label Breakfast)
        , slotView model Lunch (MealSlot.label Lunch)
        , slotView model Dinner (MealSlot.label Dinner)
        , slotView model Snack (MealSlot.label Snack)
        , let
            otherLogs : List FoodLog
            otherLogs =
                logsForSlot Other model.logs
          in
          if List.isEmpty otherLogs then
            Element.none

          else
            slotView model Other (MealSlot.label Other)
        ]


slotView : Model -> MealSlot -> String -> Element Msg
slotView model slot label =
    let
        logs : List FoodLog
        logs =
            logsForSlot slot model.logs

        totals : MacroTotals
        totals =
            macroTotals logs
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
                (Element.text (String.fromInt (round (slotCalories slot model.logs)) ++ " kcal"))
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
                    List.map (logRow model.itemNames) logs
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
                ++ "g, protein "
                ++ Nutrition.oneDecimal totals.protein
                ++ "g, fat "
                ++ Nutrition.oneDecimal totals.fat
                ++ "g"

        Percent ->
            "carbs "
                ++ String.fromInt (round totals.carbsPct)
                ++ "%, protein "
                ++ String.fromInt (round totals.proteinPct)
                ++ "%, fat "
                ++ String.fromInt (round totals.fatPct)
                ++ "%"


logRow : ItemNameLookup.Names -> FoodLog -> Element Msg
logRow itemNames log =
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
                    (Element.text
                        (ItemNameLookup.nameFor "Loading..." log.item itemNames)
                    )
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
