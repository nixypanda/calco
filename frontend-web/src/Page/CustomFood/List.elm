module Page.CustomFood.List exposing
    ( ActionState(..)
    , LoadedModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , foodSummaryText
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail)
import Api.Result as ApiResult
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients


type Model
    = Loading
    | LoadFailed String
    | Loaded LoadedModel


type alias LoadedModel =
    { foods : List ProductDetail
    , action : ActionState
    }


type ActionState
    = Idle
    | Deleting String
    | DeleteFailed String


type Msg
    = FoodsLoaded (Result Client.ApiError Foods.CustomFoodListResponse)
    | OpenFoodClicked String
    | EditFoodClicked String
    | DeleteFoodClicked String
    | DeleteCompleted String (Result Client.ApiError ())
    | CreateCustomFoodClicked
    | BackClicked


type OutMsg
    = NoOp
    | RequestFoods
    | RequestDeleteFood String
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Loading, RequestFoods )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodsLoaded result ->
            case result of
                Ok response ->
                    ( Loaded { foods = response.items, action = Idle }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        OpenFoodClicked id ->
            ( model, Cmd.none, Navigate (FoodShow id Nothing) )

        EditFoodClicked id ->
            ( model, Cmd.none, Navigate (CustomFoodEdit id) )

        DeleteFoodClicked id ->
            case model of
                Loaded loaded ->
                    case loaded.action of
                        Deleting _ ->
                            ( model, Cmd.none, NoOp )

                        _ ->
                            ( Loaded { loaded | action = Deleting id }
                            , Cmd.none
                            , RequestDeleteFood id
                            )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted id result ->
            case model of
                Loaded loaded ->
                    if loaded.action == Deleting id then
                        case result of
                            Ok _ ->
                                ( Loaded
                                    { loaded
                                        | foods = List.filter (\food -> food.id /= id) loaded.foods
                                        , action = Idle
                                    }
                                , Cmd.none
                                , NoOp
                                )

                            Err error ->
                                ApiResult.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyLoadedActionError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CreateCustomFoodClicked ->
            ( model, Cmd.none, Navigate CustomFoodCreate )

        BackClicked ->
            ( model, Cmd.none, Navigate (DiaryDay Nothing) )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


applyLoadedActionError : String -> Model -> Model
applyLoadedActionError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | action = DeleteFailed message }

        _ ->
            model


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            Loaded loaded ->
                case loaded.action of
                    DeleteFailed message ->
                        Ui.errorBanner theme message

                    _ ->
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
        Loaded loaded ->
            Ui.listCard theme
                { rows = List.map (foodRow theme device loaded.action) loaded.foods
                , createButton = Ui.ghostButton theme "+ Create Food" CreateCustomFoodClicked
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.loading theme "Loading foods..."


foodRow : Theme -> Device -> ActionState -> ProductDetail -> Element Msg
foodRow theme device action food =
    let
        macroDot : Element Msg
        macroDot =
            View.Nutrients.macroDot
                (food.nutritionSummary.per100g |> Nutrition.summaryToNutrients)
    in
    Ui.listRow
        { onSelect = OpenFoodClicked food.id
        , leading = [ macroDot ]
        , title = Ui.truncatedHeader theme device food.name
        , subtitle =
            [ Ui.mutedBody theme (foodSummaryText food)
            , Ui.chips theme food.categories
            ]
        , trailing =
            [ Ui.iconButton theme { label = "✎", title = "Edit", onPress = EditFoodClicked food.id }
            , Ui.dangerIconButton theme
                { label = "×"
                , title =
                    if action == Deleting food.id then
                        "Deleting..."

                    else
                        "Delete"
                , onPress = DeleteFoodClicked food.id
                }
            ]
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
