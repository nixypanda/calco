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
import Element.Input as Input
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Set exposing (Set)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Icon as Icon
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type Model
    = Loading DateContext
    | Loaded DateContext NutritionDetails (Set String)
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
    | NutrientAdviceToggled String


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NutritionDetailsLoaded requestDate result ->
            if not (LocalDate.equals requestDate (currentDate model)) then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok report ->
                        ( Loaded (dateContext model) report Set.empty, Cmd.none, NoOp )

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

        NutrientAdviceToggled code ->
            case model of
                Loaded context report expandedAdvice ->
                    ( Loaded context report (toggleSetMember code expandedAdvice)
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )


toggleSetMember : comparable -> Set comparable -> Set comparable
toggleSetMember value values =
    if Set.member value values then
        Set.remove value values

    else
        Set.insert value values


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

        Loaded _ report expandedAdvice ->
            Loaded context report expandedAdvice

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

        Loaded context _ _ ->
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
    UiPage.pageContainer device
        [ dateHeader theme device model
        , case model of
            Loading _ ->
                loadingView theme

            Loaded _ report expandedAdvice ->
                reportView theme report expandedAdvice

            Failed _ message ->
                Feedback.errorBanner theme message
        ]


dateHeader : Theme -> Device -> Model -> Element Msg
dateHeader theme device model =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare (currentDate model) (today model) == LT
    in
    Surface.section theme
        { header =
            Just
                (UiPage.pageHeader theme
                    { leading =
                        Just
                            (Button.iconButton device
                                theme
                                { icon = Icon.ChevronLeft
                                , title = "Previous day"
                                , onPress = Just PreviousDayClicked
                                , tone = Button.Primary
                                }
                            )
                    , title =
                        Typography.sectionTitle theme
                            (LocalDate.display (currentDate model))
                    , subtitle = Nothing
                    , actions =
                        [ if canGoNext then
                            Button.iconButton device
                                theme
                                { icon = Icon.ChevronRight
                                , title = "Next day"
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
                    }
                )
        , body = []
        , footer = Nothing
        }


loadingView : Theme -> Element msg
loadingView theme =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.barCustom theme { width = Element.fill, height = 40 }
        , Surface.card theme
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
        , Surface.card theme
            [ Skeleton.bar theme
            , Skeleton.bar theme
            ]
        ]


reportView : Theme -> NutritionDetails -> Set String -> Element Msg
reportView theme report expandedAdvice =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ coverageNotice theme report
        , overviewSection theme report.nutrients
        , nutrientSection
            theme
            expandedAdvice
            "Carbohydrates"
            Details.Carbohydrates
            report.nutrients
        , nutrientSection theme expandedAdvice "Fats" Details.Fats report.nutrients
        , nutrientSection
            theme
            expandedAdvice
            "Nutrients to limit"
            Details.Limits
            report.nutrients
        , nutrientSection
            theme
            expandedAdvice
            "Vitamins & minerals"
            Details.VitaminsMinerals
            report.nutrients
        , referenceSection theme report
        ]


overviewSection : Theme -> List Nutrient -> Element Msg
overviewSection theme nutrients =
    let
        overview : List Nutrient
        overview =
            inSection Details.Overview nutrients
    in
    Surface.section theme
        { header = Just (Typography.subsectionTitle theme "Overview")
        , body =
            if List.isEmpty overview then
                [ Feedback.loading theme "No overview data is available." ]

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


coverageLabel : Nutrient -> String
coverageLabel nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            "No data"

        Details.PartialCoverage ->
            "Known minimum"

        Details.CompleteCoverage ->
            ""


nutrientSection :
    Theme
    -> Set String
    -> String
    -> Details.NutrientSection
    -> List Nutrient
    -> Element Msg
nutrientSection theme expandedAdvice title section nutrients =
    let
        selected : List Nutrient
        selected =
            inSection section nutrients
    in
    Surface.section theme
        { header = Just (Typography.subsectionTitle theme title)
        , body =
            if List.isEmpty selected then
                [ Feedback.loading theme "No nutrient data is available for this group." ]

            else
                List.map (nutrientRow theme expandedAdvice) selected
        , footer = Nothing
        }


inSection : Details.NutrientSection -> List Nutrient -> List Nutrient
inSection section =
    List.filter (\nutrient -> nutrient.section == section)


coverageNotice : Theme -> NutritionDetails -> Element msg
coverageNotice theme report =
    let
        hasIncompleteData : Bool
        hasIncompleteData =
            report.loggedItems
                > 0
                && (hasPartialCoverage report || hasNoCoverage report)

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
    if hasIncompleteData then
        Feedback.warningBanner theme message

    else
        Feedback.infoBanner theme message


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


nutrientRow : Theme -> Set String -> Nutrient -> Element Msg
nutrientRow theme expandedAdvice nutrient =
    let
        adviceIsExpanded : Bool
        adviceIsExpanded =
            Set.member nutrient.code expandedAdvice
    in
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Input.button
            [ Element.width Element.fill ]
            { onPress = Just (NutrientAdviceToggled nutrient.code)
            , label =
                Element.column
                    [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                    [ Element.row
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ Element.paragraph
                            [ Element.width Element.fill, Font.bold, Typography.body ]
                            [ Element.text nutrient.name ]
                        , Element.el
                            [ Element.alignRight
                            , Font.color theme.textMedium
                            , Typography.body
                            ]
                            (Element.text (amountLabel nutrient))
                        ]
                    , progressView theme nutrient
                    , Element.row
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ guidanceView theme nutrient
                        , Icon.view
                            { icon =
                                if adviceIsExpanded then
                                    Icon.ChevronUp

                                else
                                    Icon.ChevronDown
                            , size = 16
                            , color = theme.textMuted
                            }
                        ]
                    ]
            }
        , if adviceIsExpanded then
            Element.paragraph
                [ Element.width Element.fill
                , Background.color theme.inputFill
                , Font.color theme.textMuted
                , Element.padding DesignTokens.space12
                , Typography.caption
                ]
                [ Element.text (dailyAdvice nutrient.code) ]

          else
            Element.none
        ]


guidanceView : Theme -> Nutrient -> Element msg
guidanceView theme nutrient =
    if nutrient.coverage == Details.PartialCoverage then
        Element.wrappedRow
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ Chip.coloredPill
                { label = "Partial data"
                , bg = theme.brandBlueSoft
                , fg = theme.brandBlue
                }
            , Element.paragraph
                [ Font.color theme.textPrimary, Typography.caption ]
                [ Element.text (guidanceSummary nutrient) ]
            ]

    else
        Element.paragraph
            [ Element.width Element.fill
            , Font.color (guidanceColor theme nutrient)
            , Typography.caption
            ]
            [ Element.text (guidanceSummary nutrient) ]


amountLabel : Nutrient -> String
amountLabel nutrient =
    case nutrient.guidanceKind of
        Details.Informational ->
            knownAmountLabel nutrient

        _ ->
            case ( nutrient.knownAmount, nutrient.referenceAmount ) of
                ( Just amount, Just referenceAmount ) ->
                    Number.toFixedTrimmed 1 amount
                        ++ " / "
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
            Feedback.linearProgress theme
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
                theme.statusGreenSoft

            Details.WithinLimit ->
                theme.statusGreenSoft

            _ ->
                theme.brandBlue


guidanceSummary : Nutrient -> String
guidanceSummary nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            "No data"

        Details.PartialCoverage ->
            case nutrient.knownAmount of
                Just amount ->
                    formatAmount amount nutrient.unit ++ " is a known minimum"

                Nothing ->
                    "No known amount"

        Details.CompleteCoverage ->
            completeGuidanceSummary nutrient


completeGuidanceSummary : Nutrient -> String
completeGuidanceSummary nutrient =
    case ( nutrient.guidanceKind, nutrient.knownAmount, nutrient.referenceAmount ) of
        ( Details.Informational, _, _ ) ->
            "No daily reference"

        ( Details.Adequacy, Just amount, Just referenceAmount ) ->
            if amount >= referenceAmount then
                "Daily reference reached"

            else
                formatAmount (referenceAmount - amount) nutrient.unit
                    ++ " to daily reference"

        ( Details.Maximum, Just amount, Just referenceAmount ) ->
            if amount > referenceAmount then
                formatAmount (amount - referenceAmount) nutrient.unit
                    ++ " over daily limit"

            else
                formatAmount (referenceAmount - amount) nutrient.unit ++ " remaining"

        _ ->
            "No daily reference"


guidanceColor : Theme -> Nutrient -> Element.Color
guidanceColor theme nutrient =
    if Details.isDangerous nutrient then
        theme.dangerFg

    else
        case ( nutrient.coverage, nutrient.status ) of
            ( Details.CompleteCoverage, Details.MetReference ) ->
                theme.statusGreenSoft

            ( Details.CompleteCoverage, Details.WithinLimit ) ->
                theme.statusGreenSoft

            _ ->
                theme.textMuted


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


referenceSection : Theme -> NutritionDetails -> Element msg
referenceSection theme report =
    Surface.section theme
        { header = Just (Typography.subsectionTitle theme "About these references")
        , body =
            [ Element.paragraph [ Font.color theme.textMuted, Typography.body ]
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
        , footer = Nothing
        }
