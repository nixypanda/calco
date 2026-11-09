module Page.NutritionDetails exposing
    ( DateCtx
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , bootSkeleton
    , init
    , isBusy
    , update
    , view
    )

import Api.Client as Client
import Data.NutritionDetails as Details exposing (Nutrient, NutritionDetails)
import Data.Route as Route exposing (Route)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Number as Number
import Set exposing (Set)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Icon as Icon
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography


type Model
    = Loading DateCtx
    | Loaded DateCtx NutritionDetails (Set String)
    | Failed DateCtx String


type alias DateCtx =
    { currentDate : LocalDate, today : LocalDate }


type OutMsg
    = NoOp
    | RequestNutritionDetails LocalDate
    | Navigate Route
    | SessionExpired


init : { date : LocalDate, today : LocalDate } -> ( Model, OutMsg )
init args =
    ( Loading { currentDate = args.date, today = args.today }, RequestNutritionDetails args.date )


{-| Only the initial fetch is busy; `Failed` is a settled error state.
-}
isBusy : Model -> Bool
isBusy model =
    case model of
        Loading _ ->
            True

        _ ->
            False


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
                        ( Loaded (dateCtx model) report Set.empty, Cmd.none, NoOp )

                    Err error ->
                        Client.failure
                            { noOp = NoOp
                            , sessionExpired = SessionExpired
                            , applyError = \message _ -> Failed (dateCtx model) message
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
                    ( Loaded context report (toggleSetMember code expandedAdvice), Cmd.none, NoOp )

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
        context : DateCtx
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
        context : DateCtx
        context =
            { currentDate = nextDate, today = today model }
    in
    ( Loading context
    , Cmd.none
    , Navigate (Route.NutritionDetails (Just nextDate))
    )


dateCtx : Model -> DateCtx
dateCtx model =
    case model of
        Loading context ->
            context

        Loaded context _ _ ->
            context

        Failed context _ ->
            context


currentDate : Model -> LocalDate
currentDate =
    dateCtx >> .currentDate


today : Model -> LocalDate
today =
    dateCtx >> .today


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        [ dateHeader env model
        , case model of
            Loading _ ->
                Skeleton.busy
                    { label = I18n.t env.language TidCommonLoading }
                    [ skeletonView env ]

            Loaded _ report expandedAdvice ->
                reportView env report expandedAdvice

            Failed _ message ->
                Feedback.errorBanner env.theme message
        ]


dateHeader : Env -> Model -> Element Msg
dateHeader env model =
    let
        canGoNext : Bool
        canGoNext =
            LocalDate.compare (currentDate model) (today model) == LT
    in
    Element.el
        [ Element.width Element.fill, UiCommon.testId "date-header" ]
        (Surface.section env.theme
            { header =
                Just
                    (UiPage.pageHeader env.theme
                        { leading =
                            Just
                                (Button.iconButton env.device
                                    env.theme
                                    { icon = Icon.ChevronLeft
                                    , title = I18n.t env.language TidNutritionDetailsPreviousDay
                                    , onPress = Just PreviousDayClicked
                                    , tone = Button.Primary
                                    }
                                )
                        , title =
                            Typography.sectionTitle env.theme
                                (LocalDate.display env.language (currentDate model))
                        , subtitle = Nothing
                        , actions =
                            [ if canGoNext then
                                Button.iconButton env.device
                                    env.theme
                                    { icon = Icon.ChevronRight
                                    , title = I18n.t env.language TidNutritionDetailsNextDay
                                    , onPress = Just NextDayClicked
                                    , tone = Button.Primary
                                    }

                              else
                                Button.iconButton env.device
                                    env.theme
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
        )


{-| The full boot body. `Page.bootstrapView` has no route model to render the
real date header from, so the boot shell includes the same 84px date-header
surface the page renders before its body skeleton. The page's own loading state
uses the real `dateHeader` and body-only `skeletonView`, so the header is never
duplicated.
-}
bootSkeleton : Env -> Element msg
bootSkeleton env =
    UiPage.pageContainer
        [ dateHeaderSkeleton env
        , skeletonView env
        ]


dateHeaderSkeleton : Env -> Element msg
dateHeaderSkeleton env =
    Element.el
        [ Element.width Element.fill, UiCommon.testId "date-header" ]
        (Surface.section env.theme
            { header =
                Just
                    (Skeleton.pageHeader
                        { leading = Just (Skeleton.icon env.theme)
                        , title =
                            Skeleton.elLine env.theme
                                { size = 24, width = Element.fill }
                        , subtitle = []
                        , actions = [ Skeleton.icon env.theme ]
                        }
                    )
            , body = []
            , footer = Nothing
            }
        )


{-| The report body below the real date header. The page's own loading state
and `Page.bootstrapView` both call this so the coverage banner, overview and
first nutrient section keep their position while the report loads.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        , UiCommon.testId "nutrition-details-skeleton"
        ]
        [ coverageBannerSkeleton env
        , overviewSkeleton env
        , nutrientSectionSkeleton env
        , nutrientSectionSkeleton env
        , nutrientSectionSkeleton env
        , nutrientSectionSkeleton env
        , referenceSkeleton env
        ]


{-| The loaded report always renders `Feedback.infoBanner` or
`Feedback.warningBanner`. The shell keeps the loaded 12px padding and 4px
paragraph line gap: one line on Tablet/Desktop and two on Phone, matching the
seeded wrap. The banner text is data-derived, so a longer message can still add
a line and is explicitly variable.
-}
coverageBannerSkeleton : Env -> Element msg
coverageBannerSkeleton env =
    let
        lineCount : Int
        lineCount =
            if UiCommon.isSmall env.device then
                2

            else
                1
    in
    Element.el
        [ Element.width Element.fill, UiCommon.testId "coverage-banner" ]
        (Element.column
            [ Element.width Element.fill
            , Element.padding DesignTokens.space12
            , Element.spacing DesignTokens.space4
            , Background.color env.theme.brandBlueSoft
            , Border.rounded DesignTokens.radiusControl
            , UiCommon.skeletonRegion
            ]
            (List.repeat lineCount
                (Skeleton.elLine env.theme
                    { size = 17, width = Element.fill }
                )
            )
        )


{-| The backend guidance defines exactly four overview rows (energy, protein,
carbohydrates and fat), so the skeleton reserves four tiles rather than a
three-tile guess that reflows at intermediate pane widths.
-}
overviewNutrientCount : Int
overviewNutrientCount =
    4


overviewSkeleton : Env -> Element msg
overviewSkeleton env =
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrition-overview" ]
        (Surface.section env.theme
            { header =
                Just
                    (Skeleton.elLine env.theme
                        { size = 20, width = Element.px 120 }
                    )
            , body =
                [ Element.wrappedRow
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space8
                    ]
                    (List.repeat overviewNutrientCount (Skeleton.stat env.theme))
                ]
            , footer = Nothing
            }
        )


nutrientSectionSkeleton : Env -> Element msg
nutrientSectionSkeleton env =
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrient-section" ]
        (Surface.section env.theme
            { header =
                Just
                    (Skeleton.elLine env.theme
                        { size = 20, width = Element.px 160 }
                    )
            , body =
                List.repeat 4 (nutrientRowSkeleton env.theme)
            , footer = Nothing
            }
        )


{-| Mirrors the tappable `nutrientRow`: a bold 16px name with a right-aligned
amount, a 10px progress bar and a 13px guidance caption. The advice chevron is
decorative and has no effect on the row's vertical rhythm.
-}
nutrientRowSkeleton : Theme -> Element msg
nutrientRowSkeleton theme =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ Skeleton.elLine theme { size = 16, width = Element.fill }
            , Skeleton.elLine theme { size = 16, width = Element.px 56 }
            ]
        , Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 10)
            , Background.color theme.inputFill
            , Border.rounded DesignTokens.radiusPill
            , UiCommon.skeletonRegion
            ]
            Element.none
        , Skeleton.elLine theme
            { size = 13, width = Element.fillPortion 2 }
        ]


referenceSkeleton : Env -> Element msg
referenceSkeleton env =
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrition-reference" ]
        (Surface.section env.theme
            { header =
                Just
                    (Skeleton.elLine env.theme
                        { size = 20, width = Element.px 160 }
                    )
            , body =
                [ Skeleton.elLine env.theme
                    { size = 17, width = Element.fill }
                , Skeleton.elLine env.theme
                    { size = 17, width = Element.fillPortion 2 }
                , Skeleton.elLine env.theme
                    { size = 17, width = Element.px 160 }
                ]
            , footer = Nothing
            }
        )


reportView : Env -> NutritionDetails -> Set String -> Element Msg
reportView env report expandedAdvice =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ coverageNotice env report
        , overviewSection env report.nutrients
        , nutrientSection env
            expandedAdvice
            (I18n.t env.language TidNutrientCarbohydrates)
            Details.Carbohydrates
            report.nutrients
        , nutrientSection env
            expandedAdvice
            (I18n.t env.language TidNutritionDetailsFats)
            Details.Fats
            report.nutrients
        , nutrientSection env
            expandedAdvice
            (I18n.t env.language TidNutritionDetailsNutrientsToLimit)
            Details.Limits
            report.nutrients
        , nutrientSection env
            expandedAdvice
            (I18n.t env.language TidNutritionDetailsVitaminsMinerals)
            Details.VitaminsMinerals
            report.nutrients
        , referenceSection env report
        ]


overviewSection : Env -> List Nutrient -> Element Msg
overviewSection env nutrients =
    let
        overview : List Nutrient
        overview =
            inSection Details.Overview nutrients
    in
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrition-overview" ]
        (Surface.section env.theme
            { header =
                Just
                    (Typography.subsectionTitle env.theme
                        (I18n.t env.language TidNutritionDetailsOverview)
                    )
            , body =
                if List.isEmpty overview then
                    [ Feedback.loading env.theme
                        (I18n.t env.language TidNutritionDetailsOverviewEmpty)
                    ]

                else
                    [ Element.wrappedRow
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        (List.map (overviewItem env) overview)
                    ]
            , footer = Nothing
            }
        )


overviewItem : Env -> Nutrient -> Element msg
overviewItem env nutrient =
    Element.column
        [ Element.width (Element.minimum 130 Element.fill)
        , Element.spacing DesignTokens.space2
        , Element.padding DesignTokens.space12
        , Background.color env.theme.inputFill
        , UiCommon.testId "stat"
        ]
        [ Element.paragraph [ Font.color env.theme.textMuted, Typography.caption ]
            [ Element.text nutrient.name ]
        , Element.paragraph [ Font.bold, Typography.body ]
            [ Element.text (knownAmountLabel nutrient) ]
        , Element.paragraph [ Font.color env.theme.textMuted, Typography.caption ]
            [ Element.text (coverageLabel env.language nutrient) ]
        ]


{-| Complete coverage returns a non-breaking space rather than an empty string
because the overview caption is always rendered: the paragraph must keep its
line box so complete, partial and no-coverage tiles share one height.
-}
coverageLabel : Language -> Nutrient -> String
coverageLabel language nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            I18n.t language TidNutritionDetailsNoData

        Details.PartialCoverage ->
            I18n.t language TidNutritionDetailsKnownMinimum

        Details.CompleteCoverage ->
            "\u{00A0}"


nutrientSection :
    Env
    -> Set String
    -> String
    -> Details.NutrientSection
    -> List Nutrient
    -> Element Msg
nutrientSection env expandedAdvice title section nutrients =
    let
        selected : List Nutrient
        selected =
            inSection section nutrients
    in
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrient-section" ]
        (Surface.section env.theme
            { header = Just (Typography.subsectionTitle env.theme title)
            , body =
                if List.isEmpty selected then
                    [ Feedback.loading env.theme
                        (I18n.t env.language TidNutritionDetailsNoNutrientData)
                    ]

                else
                    List.map (nutrientRow env expandedAdvice) selected
            , footer = Nothing
            }
        )


inSection : Details.NutrientSection -> List Nutrient -> List Nutrient
inSection section =
    List.filter (\nutrient -> nutrient.section == section)


coverageNotice : Env -> NutritionDetails -> Element msg
coverageNotice env report =
    let
        hasIncompleteData : Bool
        hasIncompleteData =
            report.loggedItems > 0 && (hasPartialCoverage report || hasNoCoverage report)

        message : String
        message =
            if report.loggedItems == 0 then
                I18n.t env.language TidNutritionDetailsNoItemsLogged

            else if hasPartialCoverage report then
                I18n.t env.language TidNutritionDetailsPartialCoverageNotice

            else if hasNoCoverage report then
                I18n.t env.language TidNutritionDetailsMissingNutrientNotice

            else if report.loggedItems == 1 then
                I18n.t env.language
                    (TidNutritionDetailsLoggedItemsIncludedOne (String.fromInt report.loggedItems))

            else
                I18n.t env.language
                    (TidNutritionDetailsLoggedItemsIncludedOther
                        (String.fromInt report.loggedItems)
                    )
    in
    if hasIncompleteData then
        Element.el [ Element.width Element.fill, UiCommon.testId "coverage-banner" ]
            (Feedback.warningBanner env.theme message)

    else
        Element.el [ Element.width Element.fill, UiCommon.testId "coverage-banner" ]
            (Feedback.infoBanner env.theme message)


hasPartialCoverage : NutritionDetails -> Bool
hasPartialCoverage report =
    List.any (\nutrient -> nutrient.coverage == Details.PartialCoverage) report.nutrients


hasNoCoverage : NutritionDetails -> Bool
hasNoCoverage report =
    List.any (\nutrient -> nutrient.coverage == Details.NoCoverage) report.nutrients


nutrientRow : Env -> Set String -> Nutrient -> Element Msg
nutrientRow env expandedAdvice nutrient =
    let
        adviceIsExpanded : Bool
        adviceIsExpanded =
            Set.member nutrient.code expandedAdvice
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
        [ Input.button [ Element.width Element.fill ]
            { onPress = Just (NutrientAdviceToggled nutrient.code)
            , label =
                Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                    [ Element.row
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ Element.paragraph
                            [ Element.width Element.fill, Font.bold, Typography.body ]
                            [ Element.text nutrient.name ]
                        , Element.el
                            [ Element.alignRight, Font.color env.theme.textMedium, Typography.body ]
                            (Element.text (amountLabel env.language nutrient))
                        ]
                    , progressView env.theme nutrient
                    , Element.row
                        [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                        [ guidanceView env nutrient
                        , Icon.view
                            { icon =
                                if adviceIsExpanded then
                                    Icon.ChevronUp

                                else
                                    Icon.ChevronDown
                            , size = 16
                            , color = env.theme.textMuted
                            }
                        ]
                    ]
            }
        , if adviceIsExpanded then
            Element.paragraph
                [ Element.width Element.fill
                , Background.color env.theme.inputFill
                , Font.color env.theme.textMuted
                , Element.padding DesignTokens.space12
                , Typography.caption
                ]
                [ Element.text (dailyAdvice env.language nutrient.code) ]

          else
            Element.none
        ]


guidanceView : Env -> Nutrient -> Element msg
guidanceView env nutrient =
    if nutrient.coverage == Details.PartialCoverage then
        Element.wrappedRow [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
            [ Chip.coloredPill
                { label = I18n.t env.language TidNutritionDetailsPartialData
                , bg = env.theme.brandBlueSoft
                , fg = env.theme.brandBlue
                }
            , Element.paragraph [ Font.color env.theme.textPrimary, Typography.caption ]
                [ Element.text (guidanceSummary env.language nutrient) ]
            ]

    else
        Element.paragraph
            [ Element.width Element.fill
            , Font.color (guidanceColor env.theme nutrient)
            , Typography.caption
            ]
            [ Element.text (guidanceSummary env.language nutrient) ]


amountLabel : Language -> Nutrient -> String
amountLabel language nutrient =
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
                    I18n.t language
                        (TidNutritionDetailsUnknownOfAmount
                            (formatAmount referenceAmount nutrient.unit)
                        )

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
                { value = percent, max = 100, color = progressColor theme nutrient }

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


guidanceSummary : Language -> Nutrient -> String
guidanceSummary language nutrient =
    case nutrient.coverage of
        Details.NoCoverage ->
            I18n.t language TidNutritionDetailsNoData

        Details.PartialCoverage ->
            case nutrient.knownAmount of
                Just amount ->
                    I18n.t language
                        (TidNutritionDetailsKnownMinimumAmount (formatAmount amount nutrient.unit))

                Nothing ->
                    I18n.t language TidNutritionDetailsNoKnownAmount

        Details.CompleteCoverage ->
            completeGuidanceSummary language nutrient


completeGuidanceSummary : Language -> Nutrient -> String
completeGuidanceSummary language nutrient =
    case ( nutrient.guidanceKind, nutrient.knownAmount, nutrient.referenceAmount ) of
        ( Details.Informational, _, _ ) ->
            I18n.t language TidNutritionDetailsNoDailyReference

        ( Details.Adequacy, Just amount, Just referenceAmount ) ->
            if amount >= referenceAmount then
                I18n.t language TidNutritionDetailsDailyReferenceReached

            else
                I18n.t language
                    (TidNutritionDetailsToDailyReference
                        (formatAmount (referenceAmount - amount) nutrient.unit)
                    )

        ( Details.Maximum, Just amount, Just referenceAmount ) ->
            if amount > referenceAmount then
                I18n.t language
                    (TidNutritionDetailsOverDailyLimit
                        (formatAmount (amount - referenceAmount) nutrient.unit)
                    )

            else
                I18n.t language
                    (TidNutritionDetailsRemaining
                        (formatAmount (referenceAmount - amount) nutrient.unit)
                    )

        _ ->
            I18n.t language TidNutritionDetailsNoDailyReference


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


dailyAdvice : Language -> String -> String
dailyAdvice language code =
    case code of
        "FIBER_G" ->
            I18n.t language TidNutritionDetailsAdviceFiber

        "SUGAR_G" ->
            I18n.t language TidNutritionDetailsAdviceSugar

        "ADDED_SUGAR_G" ->
            I18n.t language TidNutritionDetailsAdviceAddedSugar

        "SATURATED_FAT_G" ->
            I18n.t language TidNutritionDetailsAdviceSaturatedFat

        "TRANS_FAT_G" ->
            I18n.t language TidNutritionDetailsAdviceTransFat

        "MONOUNSATURATED_FAT_G" ->
            I18n.t language TidNutritionDetailsAdviceUnsaturatedFats

        "POLYUNSATURATED_FAT_G" ->
            I18n.t language TidNutritionDetailsAdviceUnsaturatedFats

        "SODIUM_MG" ->
            I18n.t language TidNutritionDetailsAdviceSodium

        "CHOLESTEROL_MG" ->
            I18n.t language TidNutritionDetailsAdviceCholesterol

        "POTASSIUM_MG" ->
            I18n.t language TidNutritionDetailsAdvicePotassium

        "CALCIUM_MG" ->
            I18n.t language TidNutritionDetailsAdviceCalcium

        "IRON_MG" ->
            I18n.t language TidNutritionDetailsAdviceIron

        "MAGNESIUM_MG" ->
            I18n.t language TidNutritionDetailsAdviceMagnesium

        "VITAMIN_D_UG" ->
            I18n.t language TidNutritionDetailsAdviceVitaminD

        "VITAMIN_B12_UG" ->
            I18n.t language TidNutritionDetailsAdviceVitaminB12

        _ ->
            I18n.t language TidNutritionDetailsAdviceDefault


formatAmount : Float -> String -> String
formatAmount amount unit =
    Number.toFixedTrimmed 1 amount ++ " " ++ unit


referenceSection : Env -> NutritionDetails -> Element msg
referenceSection env report =
    Element.el
        [ Element.width Element.fill, UiCommon.testId "nutrition-reference" ]
        (Surface.section env.theme
            { header =
                Just
                    (Typography.subsectionTitle env.theme
                        (I18n.t env.language TidNutritionDetailsAboutReferences)
                    )
            , body =
                [ Element.paragraph [ Font.color env.theme.textMuted, Typography.body ]
                    [ Element.text
                        (I18n.t env.language
                            (TidNutritionDetailsReferencesDescription
                                report.reference.name
                                report.reference.authority
                                report.reference.jurisdiction
                                report.reference.populationLabel
                            )
                        )
                    ]
                , Element.newTabLink
                    [ Font.color env.theme.brandBlue
                    , Font.underline
                    , Typography.body
                    ]
                    { url = report.reference.sourceUrl
                    , label =
                        Element.text
                            (I18n.t env.language TidNutritionDetailsViewReferenceSource)
                    }
                ]
            , footer = Nothing
            }
        )
