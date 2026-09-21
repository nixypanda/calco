module Page.CustomFood.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , foodSummaryText
    , init
    , update
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.Nutrients



-- MODEL


type Model
    = Loading
    | LoadFailed String
    | Loaded (List ProductDetail)


type OutMsg
    = NoOp
    | RequestFoods
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestFoods )



-- UPDATE


type Msg
    = FoodsLoaded (Result Client.ApiError Foods.CustomFoodListResponse)
    | OpenFoodClicked String
    | CreateWithAiClicked
    | CreateManuallyClicked
    | BackClicked


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodsLoaded result ->
            case result of
                Ok response ->
                    ( Loaded response.items, Cmd.none, NoOp )

                Err error ->
                    failure error model

        OpenFoodClicked id ->
            ( model, Cmd.none, Navigate (CustomFoodShow id) )

        CreateWithAiClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreateWithAi )

        CreateManuallyClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (DiaryDay Nothing Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }



-- VIEW


contentView :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Element Msg
contentView { model, device, theme, language } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ case model of
            Loaded _ ->
                Element.none

            LoadFailed message ->
                Feedback.errorBanner theme message

            Loading ->
                Element.none
        , bodyView theme device language model
        ]


bodyView : Theme -> Device -> Language -> Model -> Element Msg
bodyView theme device language model =
    case model of
        Loaded foods ->
            Surface.section theme
                { header =
                    Just
                        (createActions device theme language)
                , body =
                    if List.isEmpty foods then
                        [ Typography.mutedBodyParagraph
                            theme
                            (I18n.t language TidCustomFoodListEmpty)
                        ]

                    else
                        List.intersperse (Surface.hairline theme)
                            (List.map (foodRow theme device language) foods)
                , footer = Nothing
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            customFoodListSkeleton theme


createActions : Device -> Theme -> Language -> Element Msg
createActions device theme language =
    Element.row
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space12
        ]
        [ Element.el [ Element.width Element.fill ]
            (Button.textButton device
                theme
                { tone = Button.Primary
                , width = Button.FullWidth
                , label = I18n.t language TidTitleCreateWithAi
                , onPress = CreateWithAiClicked
                , submitState = Just Button.Idle
                , submittingLabel = Just (I18n.t language TidTitleCreateWithAi)
                , trailing = Nothing
                }
            )
        , Element.el [ Element.width Element.fill ]
            (Button.textButton device
                theme
                { tone = Button.PrimaryOutline
                , width = Button.FullWidth
                , label = I18n.t language TidCustomFoodEnterManually
                , onPress = CreateManuallyClicked
                , submitState = Just Button.Idle
                , submittingLabel = Just (I18n.t language TidCustomFoodEnterManually)
                , trailing = Nothing
                }
            )
        ]


foodRow : Theme -> Device -> Language -> ProductDetail -> Element Msg
foodRow theme _ language food =
    let
        macroDot : Element Msg
        macroDot =
            View.Nutrients.macroDot theme
                language
                (food.nutritionSummary.per100g |> Nutrition.summaryToNutrients)
    in
    Surface.listRow
        { onSelect = OpenFoodClicked food.id
        , leading = [ macroDot ]
        , title = Typography.wrappedListItemTitle theme food.name
        , subtitle =
            [ Typography.mutedBodyParagraph theme (foodSummaryText language food)
            , Chip.chips theme food.categories
            ]
        , trailing = []
        }


foodSummaryText : Language -> ProductDetail -> String
foodSummaryText language food =
    [ food.brand
    , Maybe.map
        (\kcal ->
            I18n.t language
                (TidSearchKcalPer100g (String.fromInt (round (Nutrition.safeAmount kcal))))
        )
        food.nutritionSummary.per100g.energyKcal
    ]
        |> Text.dotSeparated


customFoodListSkeleton : Theme -> Element msg
customFoodListSkeleton theme =
    Surface.section theme
        { header =
            Just
                (Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space12
                    ]
                    [ Element.el [ Element.width Element.fill ]
                        (Skeleton.button theme)
                    , Element.el [ Element.width Element.fill ]
                        (Skeleton.button theme)
                    ]
                )
        , body =
            List.intersperse (Surface.hairline theme)
                (List.map (\_ -> Skeleton.listRow theme)
                    (List.range 1 3)
                )
        , footer = Nothing
        }
