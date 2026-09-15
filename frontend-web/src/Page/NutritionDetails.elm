module Page.NutritionDetails exposing
    ( DateContext
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.NutritionDetails as Details exposing (Nutrient, NutritionDetails)
import Data.Route as Route exposing (Route)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Font as Font
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type Model
    = Loading DateContext
    | Loaded DateContext NutritionDetails
    | Failed DateContext String


type alias DateContext =
    { currentDate : LocalDate
    , today : LocalDate
    }


type OutMsg
    = NoOp
    | RequestNutritionDetails LocalDate
    | Navigate Route
    | SessionExpired


init : { date : LocalDate, today : LocalDate } -> ( Model, OutMsg )
init args =
    ( Loading { currentDate = args.date, today = args.today }
    , RequestNutritionDetails args.date
    )


type Msg
    = NutritionDetailsLoaded LocalDate (Result Client.ApiError NutritionDetails)
    | PreviousDayClicked
    | NextDayClicked
    | TodayChanged LocalDate


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NutritionDetailsLoaded requestDate result ->
            if not (LocalDate.equals requestDate (currentDate model)) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok report ->
                        ( Loaded (dateContext model) report, Cmd.none, NoOp )

                    Err error ->
                        Client.failure
                            { noOp = NoOp
                            , sessionExpired = SessionExpired
                            , applyError = \message _ -> Failed (dateContext model) message
                            }
                            error
                            model

        PreviousDayClicked ->
            navigateTo (LocalDate.addDays -1 (currentDate model)) model

        NextDayClicked ->
            case LocalDate.nextOnOrBefore (today model) (currentDate model) of
                Just next ->
                    navigateTo next model

                Nothing ->
                    ( model, Cmd.none, NoOp )

        TodayChanged changed ->
            ( withToday changed model, Cmd.none, NoOp )


withToday : LocalDate -> Model -> Model
withToday changed model =
    let
        context : DateContext
        context =
            { currentDate = currentDate model, today = changed }
    in
    case model of
        Loading _ ->
            Loading context

        Loaded _ report ->
            Loaded context report

        Failed _ message ->
            Failed context message


navigateTo : LocalDate -> Model -> ( Model, Cmd Msg, OutMsg )
navigateTo nextDate model =
    let
        context : DateContext
        context =
            { currentDate = nextDate, today = today model }
    in
    ( Loading context
    , Cmd.none
    , Navigate (Route.NutritionDetails (Just (LocalDate.format nextDate)))
    )


dateContext : Model -> DateContext
dateContext model =
    case model of
        Loading context ->
            context

        Loaded context _ ->
            context

        Failed context _ ->
            context


currentDate : Model -> LocalDate
currentDate =
    dateContext >> .currentDate


today : Model -> LocalDate
today =
    dateContext >> .today


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ dateHeader theme device model
        , case model of
            Loading _ ->
                loadingView theme

            Loaded _ report ->
                reportView theme report

            Failed _ message ->
                Ui.errorBanner theme message
        ]


dateHeader : Theme -> Device -> Model -> Element Msg
dateHeader theme device model =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare (currentDate model) (today model) == LT
    in
    Ui.card theme
        [ Ui.pageHeader theme
            { leading =
                Just
                    (Ui.iconButton device
                        theme
                        { icon = Icon.ChevronLeft
                        , title = "Previous day"
                        , onPress = Just PreviousDayClicked
                        , tone = Ui.Primary
                        }
                    )
            , title = Typography.sectionTitle theme "Nutrition details"
            , subtitle = Just (Ui.SubtitleText (LocalDate.display (currentDate model)))
            , actions =
                [ if canGoNext then
                    Ui.iconButton device
                        theme
                        { icon = Icon.ChevronRight
                        , title = "Next day"
                        , onPress = Just NextDayClicked
                        , tone = Ui.Primary
                        }

                  else
                    Ui.iconButton device
                        theme
                        { icon = Icon.ChevronRight
                        , title = ""
                        , onPress = Nothing
                        , tone = Ui.Primary
                        }
                ]
            }
        ]


loadingView : Theme -> Element msg
loadingView theme =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.barCustom theme { width = Element.fill, height = 40 }
        , Ui.card theme
            [ Skeleton.barCustom theme { width = Element.fillPortion 2, height = 16 }
            , Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ Skeleton.barCustom theme { width = Element.fill, height = 40 }
                , Skeleton.barCustom theme { width = Element.fill, height = 40 }
                , Skeleton.barCustom theme { width = Element.fill, height = 40 }
                ]
            ]
        , Skeleton.card theme { rows = 3 }
        , Skeleton.card theme { rows = 3 }
        , Ui.card theme
            [ Skeleton.bar theme
            , Skeleton.bar theme
            ]
        ]


reportView : Theme -> NutritionDetails -> Element Msg
reportView theme report =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ coverageNotice theme report
        , overviewSection theme report.nutrients
        , nutrientSection theme "Carbohydrates" Details.Carbohydrates report.nutrients
        , nutrientSection theme "Fats" Details.Fats report.nutrients
        , nutrientSection theme "Nutrients to limit" Details.Limits report.nutrients
        , nutrientSection theme "Vitamins & minerals" Details.VitaminsMinerals report.nutrients
        , referenceCard theme report
        ]


overviewSection : Theme -> List Nutrient -> Element Msg
overviewSection theme nutrients =
    let
        overview : List Nutrient
        overview =
            inSection Details.Overview nutrients
    in
    Ui.section theme
        { header = Just (Typography.subsectionTitle theme "Overview")
        , body =
            if List.isEmpty overview then
                [ Ui.loading theme "No overview data is available." ]

            else
                [ Element.wrappedRow
                    [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                    (List.map (overviewItem theme) overview)
                ]
        , footer = Nothing
        }


overviewItem : Theme -> Nutrient -> Element msg
overviewItem theme nutrient =
    Element.column
        [ Element.width (Element.minimum 130 Element.fill)
        , Element.spacing DesignTokens.space2
        , Element.padding DesignTokens.space12
        , Background.color theme.inputFill
        ]
        [ Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
            [ Element.text nutrient.name ]
        , Element.paragraph [ Font.bold, Typography.body ]
            [ Element.text (knownAmountLabel nutrient) ]
        , if nutrient.coverage == Details.CompleteCoverage then
            Element.none

          else
            Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
                [ Element.text (coverageLabel nutrient) ]
        ]


nutrientSection : Theme -> String -> Details.NutrientSection -> List Nutrient -> Element Msg
nutrientSection theme title section nutrients =
    let
        selected : List Nutrient
        selected =
            inSection section nutrients
    in
    Ui.section theme
        { header = Just (Typography.subsectionTitle theme title)
        , body =
            if List.isEmpty selected then
                [ Ui.loading theme "No nutrient data is available for this group." ]

            else
                selected
                    |> List.map (nutrientRow theme)
                    |> List.intersperse (Ui.hairline theme)
        , footer = Nothing
        }


inSection : Details.NutrientSection -> List Nutrient -> List Nutrient
inSection section =
    List.filter (\nutrient -> nutrient.section == section)


coverageNotice : Theme -> NutritionDetails -> Element msg
coverageNotice theme report =
    let
        message : String
        message =
            if report.loggedItems == 0 then
                "No items were logged for this day, so nutrition details are unavailable."

            else if hasPartialCoverage report then
                "Some logged items have incomplete nutrition data. "
                    ++ "Partial amounts are known minimums."

            else if hasNoCoverage report then
                "Some logged items do not report every nutrient, so those totals are unavailable."

            else
                String.fromInt report.loggedItems
                    ++ loggedItemLabel report.loggedItems
                    ++ includedVerb report.loggedItems
                    ++ " included in these daily totals."
    in
    Element.paragraph
        [ Element.width Element.fill
        , Background.color theme.brandBlueSoft
        , Font.color theme.textMedium
        , Element.padding DesignTokens.space16
        ]
        [ Element.text message ]


hasPartialCoverage : NutritionDetails -> Bool
hasPartialCoverage report =
    List.any (\nutrient -> nutrient.coverage == Details.PartialCoverage) report.nutrients


hasNoCoverage : NutritionDetails -> Bool
hasNoCoverage report =
    List.any (\nutrient -> nutrient.coverage == Details.NoCoverage) report.nutrients


loggedItemLabel : Int -> String
loggedItemLabel count =
    if count == 1 then
        " logged item "

    else
        " logged items "


includedVerb : Int -> String
includedVerb count =
    if count == 1 then
        "is"

    else
        "are"


nutrientRow : Theme -> Nutrient -> Element msg
nutrientRow theme nutrient =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.wrappedRow
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space2 ]
                [ Element.paragraph [ Font.bold, Typography.body ] [ Element.text nutrient.name ]
                , referenceLabel theme nutrient
                ]
            , statusPill theme nutrient
            ]
        , Element.paragraph [ Font.color theme.textMedium, Typography.body ]
            [ Element.text (amountLabel nutrient) ]
        , progressView theme nutrient
        , Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
            [ Element.text (coverageAndStatusMessage nutrient) ]
        , Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
            [ Element.text (dailyAdvice nutrient.code) ]
        ]


referenceLabel : Theme -> Nutrient -> Element msg
referenceLabel theme nutrient =
    case nutrient.guidanceKind of
        Details.Informational ->
            Element.none

        Details.Maximum ->
            Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
                [ Element.text "Daily limit" ]

        Details.Adequacy ->
            Element.paragraph [ Font.color theme.textMuted, Typography.caption ]
                [ Element.text "Daily reference" ]


amountLabel : Nutrient -> String
amountLabel nutrient =
    case nutrient.guidanceKind of
        Details.Informational ->
            knownAmountLabel nutrient

        _ ->
            case ( nutrient.knownAmount, nutrient.referenceAmount ) of
                ( Just amount, Just referenceAmount ) ->
                    formatAmount amount nutrient.unit
                        ++ " of "
                        ++ formatAmount referenceAmount nutrient.unit

                ( Nothing, Just referenceAmount ) ->
                    "— of " ++ formatAmount referenceAmount nutrient.unit

                ( Just amount, Nothing ) ->
                    formatAmount amount nutrient.unit

                ( Nothing, Nothing ) ->
                    "—"


knownAmountLabel : Nutrient -> String
knownAmountLabel nutrient =
    nutrient.knownAmount
        |> Maybe.map (\amount -> formatAmount amount nutrient.unit)
        |> Maybe.withDefault "—"


progressView : Theme -> Nutrient -> Element msg
progressView theme nutrient =
    case Details.progressPercent nutrient of
        Just percent ->
            Ui.linearProgress theme
                { value = percent
                , max = 100
                , color = progressColor theme nutrient
                }

        Nothing ->
            Element.none


progressColor : Theme -> Nutrient -> Element.Color
progressColor theme nutrient =
    if Details.isDangerous nutrient then
        theme.dangerSolid

    else
        case nutrient.status of
            Details.MetReference ->
                theme.statusGreen

            Details.WithinLimit ->
                theme.statusGreen

            _ ->
                theme.brandBlue


statusPill : Theme -> Nutrient -> Element msg
statusPill theme nutrient =
    if nutrient.guidanceKind == Details.Informational && nutrient.status == Details.Available then
        Element.none

    else
        let
            dangerous : Bool
            dangerous =
                Details.isDangerous nutrient

            positive : Bool
            positive =
                nutrient.status == Details.MetReference || nutrient.status == Details.WithinLimit
        in
        Ui.coloredPill
            { label = statusLabel nutrient.status
            , bg =
                if dangerous then
                    theme.dangerBg

                else if positive then
                    theme.statusActiveBg

                else
                    theme.chipBg
            , fg =
                if dangerous then
                    theme.dangerFg

                else if positive then
                    theme.statusGreen

                else
                    theme.textMedium
            }


statusLabel : Details.NutrientStatus -> String
statusLabel status =
    case status of
        Details.NoData ->
            "No data"

        Details.PartialData ->
            "Partial data"

        Details.Available ->
            "Available"

        Details.BelowReference ->
            "Below reference"

        Details.MetReference ->
            "Reference met"

        Details.WithinLimit ->
            "Within limit"

        Details.OverLimit ->
            "Over limit"


coverageAndStatusMessage : Nutrient -> String
coverageAndStatusMessage nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            "No logged items report " ++ String.toLower nutrient.name ++ "."

        Details.PartialCoverage ->
            case nutrient.knownAmount of
                Just amount ->
                    "Some logged items don’t report "
                        ++ String.toLower nutrient.name
                        ++ ". "
                        ++ formatAmount amount nutrient.unit
                        ++ " is a known minimum."

                Nothing ->
                    "Some logged items don’t report "
                        ++ String.toLower nutrient.name
                        ++ "; no known amount is available."

        Details.CompleteCoverage ->
            completeCoverageMessage nutrient


coverageLabel : Nutrient -> String
coverageLabel nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            "No data"

        Details.PartialCoverage ->
            "Known minimum"

        Details.CompleteCoverage ->
            ""


completeCoverageMessage : Nutrient -> String
completeCoverageMessage nutrient =
    case nutrient.status of
        Details.NoData ->
            "No amount is available for this day."

        Details.PartialData ->
            "This total is incomplete."

        Details.Available ->
            "This reflects the items logged for this day."

        Details.BelowReference ->
            "This is one day’s total, not a diagnosis of deficiency."

        Details.MetReference ->
            "You reached this daily reference."

        Details.WithinLimit ->
            "This is within the daily limit."

        Details.OverLimit ->
            "This is above the daily limit for this day."


dailyAdvice : String -> String
dailyAdvice code =
    case code of
        "FIBER_G" ->
            "Fiber supports digestive health. One day below the reference "
                ++ "does not indicate a deficiency."

        "SUGAR_G" ->
            "Includes naturally occurring and added sugars; "
                ++ "FDA sets no Daily Value for total sugars."

        "ADDED_SUGAR_G" ->
            "Added sugars have a daily limit, not a target."

        "SATURATED_FAT_G" ->
            "This is a daily limit. Replacing some saturated fat with unsaturated fat "
                ++ "is generally more useful than simply removing fat."

        "TRANS_FAT_G" ->
            "No FDA Daily Value; keep intake as low as practical."

        "MONOUNSATURATED_FAT_G" ->
            "Unsaturated fats provide context for fat quality; there is no single FDA daily target."

        "POLYUNSATURATED_FAT_G" ->
            "Unsaturated fats provide context for fat quality; there is no single FDA daily target."

        "SODIUM_MG" ->
            "Sodium is a daily limit, not a target to chase."

        "CHOLESTEROL_MG" ->
            "Dietary cholesterol is only one influence on blood cholesterol; "
                ++ "saturated and trans fats are often more actionable."

        "POTASSIUM_MG" ->
            "Potassium is shown against the FDA daily reference."

        "CALCIUM_MG" ->
            "Calcium totals reflect your logged items."

        "IRON_MG" ->
            "Iron needs vary by life stage; this is a general reference."

        "MAGNESIUM_MG" ->
            "The FDA Daily Value is 420 mg. For adults, the National Academies’ "
                ++ "350 mg upper limit applies only to magnesium from supplements and "
                ++ "medications, not food."

        "VITAMIN_D_UG" ->
            "Vitamin D in logged items is only one part of your overall intake."

        "VITAMIN_B12_UG" ->
            "More than the daily reference is not shown as a warning."

        _ ->
            "This reflects the items logged for this day."


formatAmount : Float -> String -> String
formatAmount amount unit =
    Number.toFixedTrimmed 1 amount ++ " " ++ unit


referenceCard : Theme -> NutritionDetails -> Element msg
referenceCard theme report =
    Ui.card theme
        [ Typography.subsectionTitle theme "About these references"
        , Element.paragraph [ Font.color theme.textMuted, Typography.body ]
            [ Element.text
                ("These comparisons use "
                    ++ report.reference.name
                    ++ " from "
                    ++ report.reference.authority
                    ++ " ("
                    ++ report.reference.jurisdiction
                    ++ ") for "
                    ++ report.reference.populationLabel
                    ++ ". They are informational daily comparisons, not medical diagnoses."
                )
            ]
        , Element.newTabLink
            [ Font.color theme.brandBlue, Font.underline, Typography.body ]
            { url = report.reference.sourceUrl
            , label = Element.text "View reference source"
            }
        ]
