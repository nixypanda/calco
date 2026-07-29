module Page.CustomFood.List exposing
    ( Model(..)
    , Msg(..)
    , OutMsg(..)
    , foodSummaryText
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
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
    | CreateCustomFoodClicked
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

        CreateCustomFoodClicked ->
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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            Loaded _ ->
                Element.none

            LoadFailed message ->
                Ui.errorBanner theme message

            Loading ->
                Element.none
        , bodyView theme device model
        ]


bodyView : Theme -> Device -> Model -> Element Msg
bodyView theme device model =
    case model of
        Loaded foods ->
            Ui.listCard theme
                { rows = List.map (foodRow theme device) foods
                , footer =
                    Just
                        (Ui.fullWidthGhostButton
                            device
                            theme
                            "+ Create Food"
                            CreateCustomFoodClicked
                        )
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.skeletonLoading theme


foodRow : Theme -> Device -> ProductDetail -> Element Msg
foodRow theme _ food =
    let
        macroDot : Element Msg
        macroDot =
            View.Nutrients.macroDot theme
                (food.nutritionSummary.per100g |> Nutrition.summaryToNutrients)
    in
    Ui.listRow
        { onSelect = OpenFoodClicked food.id
        , leading = [ macroDot ]
        , title = Typography.wrappedListItemTitle theme food.name
        , subtitle =
            [ Typography.mutedBodyParagraph theme (foodSummaryText food)
            , Ui.chips theme food.categories
            ]
        , trailing = []
        }


foodSummaryText : ProductDetail -> String
foodSummaryText food =
    [ food.brand
    , Maybe.map
        (\kcal ->
            String.fromInt (round (Nutrition.safeAmount kcal))
                ++ " kcal per 100 g"
        )
        food.nutritionSummary.per100g.energyKcal
    ]
        |> Ui.dotSeparated
