module Page.CustomFood.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , init
    , isBusy
    , skeletonView
    , update
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
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


{-| Only the initial fetch is busy; `LoadFailed` is a settled error state.
-}
isBusy : Model -> Bool
isBusy model =
    case model of
        Loading ->
            True

        _ ->
            False



-- UPDATE


type Msg
    = FoodsLoaded (Result Client.ApiError Foods.CustomFoodListResponse)
    | OpenFoodClicked String
    | CreateWithAiClicked
    | CreateManuallyClicked


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


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }



-- VIEW


contentView : Env -> Model -> Element Msg
contentView env model =
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ case model of
            Loaded _ ->
                Element.none

            LoadFailed message ->
                Feedback.errorBanner env.theme message

            Loading ->
                Element.none
        , bodyView env model
        ]


bodyView : Env -> Model -> Element Msg
bodyView env model =
    case model of
        Loaded foods ->
            Surface.section env.theme
                { header =
                    Just (createActions env)
                , body =
                    if List.isEmpty foods then
                        [ Typography.mutedBodyParagraph env.theme
                            (I18n.t env.language TidCustomFoodListEmpty)
                        ]

                    else
                        List.intersperse (Surface.hairline env.theme) (List.map (foodRow env) foods)
                , footer = Nothing
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Skeleton.busy
                { label = I18n.t env.language TidCommonLoading }
                [ skeletonView env ]


createActions : Env -> Element Msg
createActions env =
    Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Element.el [ Element.width Element.fill ]
            (Button.textButton env.device
                env.theme
                { tone = Button.Primary
                , width = Button.FullWidth
                , label = I18n.t env.language TidTitleCreateWithAi
                , onPress = CreateWithAiClicked
                , submitState = Just Button.Idle
                , submittingLabel = Just (I18n.t env.language TidTitleCreateWithAi)
                , trailing = Nothing
                }
            )
        , Element.el [ Element.width Element.fill ]
            (Button.textButton env.device
                env.theme
                { tone = Button.PrimaryOutline
                , width = Button.FullWidth
                , label = I18n.t env.language TidCustomFoodEnterManually
                , onPress = CreateManuallyClicked
                , submitState = Just Button.Idle
                , submittingLabel = Just (I18n.t env.language TidCustomFoodEnterManually)
                , trailing = Nothing
                }
            )
        ]


foodRow : Env -> ProductDetail -> Element Msg
foodRow env food =
    let
        macroDot : Element Msg
        macroDot =
            View.Nutrients.macroDot env
                (food.nutritionSummary.per100g |> Nutrition.summaryToNutrients)
    in
    Surface.listRow
        { onSelect = OpenFoodClicked food.id
        , leading = [ macroDot ]
        , title = Typography.wrappedListItemTitle env.theme food.name
        , subtitle =
            [ Typography.mutedBodyParagraph env.theme (foodSummaryText env.language food)
            , Chip.chips env.theme food.categories
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


{-| The page body below `contentView`'s column. The caller owns the single
`Skeleton.busy` wrapper so the page view and `Page.bootstrapView` cannot nest
status regions.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Surface.section env.theme
        { header =
            Just
                (Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space12
                    ]
                    [ Element.el [ Element.width Element.fill ]
                        (Skeleton.button env.theme)
                    , Element.el [ Element.width Element.fill ]
                        (Skeleton.button env.theme)
                    ]
                )
        , body =
            List.intersperse (Surface.hairline env.theme)
                (List.map (\_ -> foodRowSkeleton env) (List.range 1 3))
        , footer = Nothing
        }


foodRowSkeleton : Env -> Element msg
foodRowSkeleton env =
    Skeleton.row
        { leading = [ Skeleton.dot env.theme ]
        , -- The loaded title is a single-line 16px paragraph; its measured line
          -- box is 17px in this app.
          title = Skeleton.elLine env.theme { size = 17, width = Element.fill }
        , subtitle =
            [ Skeleton.elLine env.theme { size = 17, width = Element.fill }
            , Skeleton.categoryChipRow env.theme { count = 3 }
            ]
        , trailing = []
        }
