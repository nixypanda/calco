module Page.Diary exposing
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
import Data.FoodLog as FoodLog exposing (FoodLog, GroupedLogs, SummaryResponse)
import Data.ItemRef exposing (ItemRef)
import Data.LocalDate as LocalDate exposing (LocalDate)
import Data.Nutrition as Nutrition exposing (MacroTotals, NutrientAmount)
import Dict exposing (Dict)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Route exposing (MealSlot(..), Route(..))
import Ui


type MacroMode
    = Grams
    | Percent


type alias Model =
    { currentDate : LocalDate
    , today : LocalDate
    , logs : List FoodLog
    , summary : List NutrientAmount
    , itemNames : Dict String String
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
      , itemNames = Dict.empty
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
                    ( { model | summary = response.totals, loading = False, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        NameLookupCompleted item result ->
            let
                name : String
                name =
                    case result of
                        Ok value ->
                            value

                        Err _ ->
                            unknownName item
            in
            ( { model | itemNames = Dict.insert (itemKey item) name model.itemNames }, Cmd.none, NoOp )

        PreviousDayClicked ->
            let
                previous : LocalDate
                previous =
                    LocalDate.addDays -1 model.currentDate
            in
            ( { model | currentDate = previous, loading = True, error = Nothing }, Cmd.none, Navigate (Diary (Just (LocalDate.format previous))) )

        NextDayClicked ->
            let
                next : LocalDate
                next =
                    LocalDate.addDays 1 model.currentDate
            in
            case LocalDate.compare next model.today of
                GT ->
                    ( model, Cmd.none, NoOp )

                _ ->
                    ( { model | currentDate = next, loading = True, error = Nothing }, Cmd.none, Navigate (Diary (Just (LocalDate.format next))) )

        MacroModeToggled ->
            ( { model | macroMode = toggleMacroMode model.macroMode }, Cmd.none, NoOp )

        AddFoodClicked slot ->
            ( model, Cmd.none, Navigate (addFoodRoute slot) )

        LogClicked id ->
            ( model, Cmd.none, Navigate (FoodLogDetail id) )

        MealsClicked ->
            ( model, Cmd.none, Navigate Meals )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( { model | loading = False, error = Just (Client.displayError error) }, Cmd.none, SessionExpired )

    else
        ( { model | loading = False, error = Just (Client.displayError error) }, Cmd.none, NoOp )


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
    summaryValue "ENERGY_KCAL" summary
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


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
uniqueItems logs =
    let
        step : FoodLog -> ( Dict String ItemRef, List ItemRef ) -> ( Dict String ItemRef, List ItemRef )
        step log ( seen, items ) =
            let
                key : String
                key =
                    itemKey log.item
            in
            if Dict.member key seen then
                ( seen, items )

            else
                ( Dict.insert key log.item seen, log.item :: items )
    in
    logs
        |> List.foldl step ( Dict.empty, [] )
        |> Tuple.second
        |> List.reverse


itemKey : ItemRef -> String
itemKey item =
    item.itemType ++ ":" ++ item.id


unknownName : ItemRef -> String
unknownName item =
    case item.itemType of
        "meal" ->
            "Unknown meal"

        _ ->
            "Unknown food"


logsForSlot : MealSlot -> List FoodLog -> List FoodLog
logsForSlot slot logs =
    let
        matches : FoodLog -> Bool
        matches log =
            case slot of
                Breakfast ->
                    log.mealSlot == Just "breakfast"

                Lunch ->
                    log.mealSlot == Just "lunch"

                Dinner ->
                    log.mealSlot == Just "dinner"

                Snack ->
                    log.mealSlot == Just "snack"

                Other ->
                    not (List.member log.mealSlot [ Just "breakfast", Just "lunch", Just "dinner", Just "snack" ])
    in
    List.filter matches logs


view : Model -> Element Msg
view model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        , Element.padding 24
        ]
        [ topActions
        , dateCard model
        , case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , if model.loading then
            Element.el [ Font.color (Element.rgb255 107 114 128) ] (Element.text "Loading diary...")

          else if List.isEmpty model.logs then
            Element.el [ Font.color (Element.rgb255 107 114 128) ] (Element.text "No food logged for this day.")

          else
            logGroupsView model
        ]


topActions : Element Msg
topActions =
    Element.row [ Element.width Element.fill, Element.spacing 12 ]
        [ Ui.button "My Meals" MealsClicked
        ]


dateCard : Model -> Element Msg
dateCard model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        , Element.padding 16
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing 12
            ]
            [ smallButton "Previous" PreviousDayClicked
            , Element.el [ Element.width Element.fill, Font.center, Font.bold ] (Element.text (LocalDate.display model.currentDate))
            , Input.button
                [ Background.color
                    (if LocalDate.compare model.currentDate model.today == EQ then
                        Element.rgb255 229 231 235

                     else
                        Element.rgb255 17 100 102
                    )
                , Font.color
                    (if LocalDate.compare model.currentDate model.today == EQ then
                        Element.rgb255 107 114 128

                     else
                        Element.rgb255 255 255 255
                    )
                , Border.rounded 6
                , Element.paddingXY 12 8
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
    Element.wrappedRow [ Element.spacing 12 ]
        [ nutrientPill "Calories" "kcal" (dailyCalories summary)
        , nutrientPill "Protein" "g" (summaryAmount "PROTEIN_G" summary)
        , nutrientPill "Carbs" "g" (summaryAmount "CARBS_G" summary)
        , nutrientPill "Fat" "g" (summaryAmount "FAT_G" summary)
        ]


summaryAmount : String -> List NutrientAmount -> Float
summaryAmount code summary =
    summaryValue code summary
        |> Maybe.map (.amount >> Nutrition.safeAmount)
        |> Maybe.withDefault 0


nutrientPill : String -> String -> Float -> Element Msg
nutrientPill label unit amount =
    Element.column
        [ Element.spacing 4
        , Element.padding 10
        , Border.rounded 6
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        [ Element.el [ Font.bold ] (Element.text (String.fromInt (round amount) ++ " " ++ unit))
        , Element.el [ Font.size 12, Font.color (Element.rgb255 107 114 128) ] (Element.text label)
        ]


logGroupsView : Model -> Element Msg
logGroupsView model =
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
        [ slotView model Breakfast "Breakfast"
        , slotView model Lunch "Lunch"
        , slotView model Dinner "Dinner"
        , slotView model Snack "Snack"
        , let
            otherLogs : List FoodLog
            otherLogs =
                logsForSlot Other model.logs
          in
          if List.isEmpty otherLogs then
            Element.none

          else
            slotView model Other "Other"
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
    Element.column
        [ Element.width Element.fill
        , Background.color (Element.rgb255 255 255 255)
        , Border.rounded 8
        , Border.width 1
        , Border.color (Element.rgb255 229 231 235)
        ]
        (Element.row [ Element.width Element.fill, Element.padding 14, Element.spacing 12 ]
            [ Element.column [ Element.width Element.fill, Element.spacing 4 ]
                [ Element.el [ Font.bold ] (Element.text label)
                , Input.button [ Font.color (Element.rgb255 107 114 128), Font.size 13 ]
                    { onPress = Just MacroModeToggled
                    , label = Element.text (macroSummary model.macroMode totals)
                    }
                ]
            , Element.el [ Font.size 13, Font.color (Element.rgb255 107 114 128) ] (Element.text (String.fromInt (round (slotCalories slot model.logs)) ++ " kcal"))
            ]
            :: (if List.isEmpty logs then
                    [ Element.el [ Element.padding 14, Font.color (Element.rgb255 107 114 128), Element.centerX ] (Element.text "No items") ]

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
                            , Border.color (Element.rgb255 229 231 235)
                            , Font.color (Element.rgb255 17 100 102)
                            , Font.medium
                            ]
                            { onPress = Just (AddFoodClicked slot), label = Element.text "Add Food" }
                        ]
               )
        )


macroSummary : MacroMode -> MacroTotals -> String
macroSummary mode totals =
    case mode of
        Grams ->
            "carbs " ++ oneDecimal totals.carbs ++ "g, protein " ++ oneDecimal totals.protein ++ "g, fat " ++ oneDecimal totals.fat ++ "g"

        Percent ->
            "carbs " ++ String.fromInt (round totals.carbsPct) ++ "%, protein " ++ String.fromInt (round totals.proteinPct) ++ "%, fat " ++ String.fromInt (round totals.fatPct) ++ "%"


logRow : Dict String String -> FoodLog -> Element Msg
logRow itemNames log =
    Input.button
        [ Element.width Element.fill
        , Element.padding 12
        , Border.widthEach { top = 1, right = 0, bottom = 0, left = 0 }
        , Border.color (Element.rgb255 229 231 235)
        ]
        { onPress = Just (LogClicked log.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing 12 ]
                [ Element.el [ Element.width Element.fill, Font.medium ] (Element.text (Dict.get (itemKey log.item) itemNames |> Maybe.withDefault "Loading..."))
                , Element.el [ Font.size 13, Font.color (Element.rgb255 107 114 128) ] (Element.text (log.quantity.amount ++ " " ++ log.quantity.unit))
                , Element.el [ Font.size 13, Font.color (Element.rgb255 107 114 128) ] (Element.text (String.fromInt (round (Nutrition.caloriesFrom log.nutrients)) ++ " kcal"))
                ]
        }


smallButton : String -> Msg -> Element Msg
smallButton label msg =
    Input.button
        [ Background.color (Element.rgb255 17 100 102)
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 6
        , Element.paddingXY 12 8
        ]
        { onPress = Just msg
        , label = Element.text label
        }


oneDecimal : Float -> String
oneDecimal value =
    let
        scaled : Int
        scaled =
            round (value * 10)

        whole : Int
        whole =
            scaled // 10

        decimal : Int
        decimal =
            abs (modBy 10 scaled)
    in
    String.fromInt whole ++ "." ++ String.fromInt decimal
