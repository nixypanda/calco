module Page.Diary.Day exposing
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
import Data.FoodLog exposing (FoodLog)
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
import View.Nutrients


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
            , Navigate (DiaryDay (Just (LocalDate.format previous)))
            )

        NextDayClicked ->
            case LocalDate.nextOnOrBefore model.today model.currentDate of
                Just next ->
                    ( { model | currentDate = next, diary = Loading next }
                    , Cmd.none
                    , Navigate (DiaryDay (Just (LocalDate.format next)))
                    )

                Nothing ->
                    ( model, Cmd.none, NoOp )

        MacroModeToggled ->
            ( { model | macroMode = toggleMacroMode model.macroMode }, Cmd.none, NoOp )

        AddFoodClicked slot ->
            ( model, Cmd.none, Navigate (FoodSearch (Just slot)) )

        LogClicked id ->
            ( model, Cmd.none, Navigate (FoodLogEntry id) )

        MealsClicked ->
            ( model, Cmd.none, Navigate MealList )


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


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        (dateCard model device
            :: (case model.diary of
                    Loading _ ->
                        [ Ui.skeletonLoading ]

                    Loaded date logs ->
                        if LocalDate.equals date model.currentDate then
                            [ logGroupsView model logs device ]

                        else
                            [ Ui.skeletonLoading ]

                    Failed date message ->
                        if LocalDate.equals date model.currentDate then
                            [ Ui.errorBanner message ]

                        else
                            [ Ui.skeletonLoading ]
               )
        )


dateCard : Model -> Device -> Element Msg
dateCard model _ =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare model.currentDate model.today == LT
    in
    Ui.card
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing Ui.space12
            ]
            [ Ui.iconButton { label = "←", title = "Previous Day", onPress = PreviousDayClicked }
            , Element.el
                [ Element.width Element.fill
                , Font.center
                ]
                (Ui.subsectionTitle (LocalDate.display model.currentDate))
            , if canGoNext then
                Ui.iconButton { label = "→", title = "Next Day", onPress = NextDayClicked }

              else
                Input.button
                    [ Element.width (Element.px 40)
                    , Element.height (Element.px 40)
                    , Background.color Ui.inputFill
                    , Font.color Ui.mutedColor
                    , Font.center
                    , Border.rounded 999
                    ]
                    { onPress = Nothing
                    , label = Element.text "→"
                    }
            ]
        , Ui.hairline
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = 8, right = 0, bottom = 0, left = 0 }
            ]
            [ totalsView (totalsFromLogs (loadedLogs model.currentDate model.diary)) ]
        ]


totalsView : List NutrientAmount -> Element Msg
totalsView summary =
    Element.column [ Element.width Element.fill, Element.spacing 18 ]
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


logGroupsView : Model -> List FoodLog -> Device -> Element Msg
logGroupsView model logs device =
    Element.column [ Element.width Element.fill, Element.spacing Ui.space12 ]
        [ slotView model logs Breakfast (MealSlot.label Breakfast) device
        , slotView model logs Lunch (MealSlot.label Lunch) device
        , slotView model logs Dinner (MealSlot.label Dinner) device
        , slotView model logs Snack (MealSlot.label Snack) device
        , let
            otherLogs : List FoodLog
            otherLogs =
                logsForSlot Other logs
          in
          if List.isEmpty otherLogs then
            Element.none

          else
            slotView model logs Other (MealSlot.label Other) device
        ]


slotView : Model -> List FoodLog -> MealSlot -> String -> Device -> Element Msg
slotView model allLogs slot label device =
    let
        logs : List FoodLog
        logs =
            logsForSlot slot allLogs

        totals : MacroTotals
        totals =
            Nutrition.macroTotals logs
    in
    mealSlotCard slot
        (mealSlotHeader model allLogs slot label totals device)
        (Ui.hairline
            :: (if List.isEmpty logs then
                    [ Element.el
                        [ Element.padding 14
                        , Font.color Ui.mutedColor
                        , Element.centerX
                        ]
                        (Element.text "No items")
                    ]

                else
                    List.map (logRow device) logs
               )
            ++ (case slot of
                    Other ->
                        []

                    _ ->
                        [ Ui.hairline
                        , Ui.ghostButton "+ Add Food" (AddFoodClicked slot)
                        ]
               )
        )


mealSlotHeader : Model -> List FoodLog -> MealSlot -> String -> MacroTotals -> Device -> Element Msg
mealSlotHeader model allLogs slot label totals device =
    let
        horizontalPadding : Int
        horizontalPadding =
            if Ui.isSmall device then
                16

            else
                34

        headerContent : Element Msg
        headerContent =
            Element.row
                [ Element.width Element.fill
                , Element.padding 14
                , Element.spacing Ui.space12
                ]
                [ Element.column [ Element.width Element.fill, Element.spacing Ui.space4 ]
                    [ Ui.sectionTitle label
                    , Input.button []
                        { onPress = Just MacroModeToggled
                        , label = Ui.mutedCaption (macroSummary model.macroMode totals)
                        }
                    ]
                , Ui.mutedCaption
                    (String.fromInt (round (slotCalories slot allLogs)) ++ " kcal")
                ]
    in
    case slot of
        Other ->
            headerContent

        _ ->
            Element.el
                (List.concat
                    [ [ Element.width Element.fill
                      , Element.height (Element.px mealSlotHeaderHeight)
                      , Border.roundEach
                            { topLeft = 20
                            , topRight = 20
                            , bottomLeft = 0
                            , bottomRight = 0
                            }
                      , Element.clip
                      , Element.inFront mealSlotFade
                      , Element.inFront
                            (Element.el
                                [ Element.width Element.fill
                                , Element.height Element.fill
                                , Element.paddingEach
                                    { top = 38
                                    , right = horizontalPadding
                                    , bottom = 20
                                    , left = horizontalPadding
                                    }
                                ]
                                headerContent
                            )
                      ]
                    , mealSlotBackground slot
                    ]
                )
                Element.none


mealSlotHeaderHeight : Int
mealSlotHeaderHeight =
    118


mealSlotFade : Element msg
mealSlotFade =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.htmlAttribute
            (Html.Attributes.style
                "background-image"
                ("linear-gradient(to bottom, "
                    ++ "rgba(255,255,255,0) 0%, "
                    ++ "rgba(255,255,255,0) 55%, "
                    ++ "rgba(255,255,255,0.48) 85%, "
                    ++ "white 100%)"
                )
            )
        ]
        Element.none


mealSlotCard : MealSlot -> Element Msg -> List (Element Msg) -> Element Msg
mealSlotCard slot header bodyChildren =
    case slot of
        Other ->
            Ui.card (header :: bodyChildren)

        _ ->
            Element.column
                [ Element.width Element.fill
                , Background.color Ui.cardBg
                , Border.rounded 20
                , Ui.cardShadow
                , Element.spacing 0
                ]
                [ header
                , Element.column
                    [ Element.width Element.fill
                    , Element.paddingEach { top = 0, right = 20, bottom = 20, left = 20 }
                    , Element.spacing Ui.space12
                    ]
                    bodyChildren
                ]


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


logRow : Device -> FoodLog -> Element Msg
logRow device log =
    Input.button
        [ Element.width Element.fill
        , Element.padding 14
        ]
        { onPress = Just (LogClicked log.id)
        , label =
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ View.Nutrients.macroDot log.nutrients
                , Element.el
                    [ Element.width Element.fill, Font.medium, Element.clip ]
                    (Element.text
                        (Ui.truncateWithEllipsis (Ui.truncationCap device) log.item.name)
                    )
                , Ui.mutedCaption (log.quantity.amount ++ " " ++ log.quantity.unit)
                , Ui.mutedCaption
                    (String.fromInt (round (caloriesFrom log.nutrients)) ++ " kcal")
                ]
        }
