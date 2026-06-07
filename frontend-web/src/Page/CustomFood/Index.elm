module Page.CustomFood.Index exposing
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
            ( model, Cmd.none, Navigate (FoodDetail id Nothing) )

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
            ( model, Cmd.none, Navigate (Diary Nothing) )


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


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ case model of
            Loaded loaded ->
                case loaded.action of
                    DeleteFailed message ->
                        Ui.errorBanner message

                    _ ->
                        Element.none

            LoadFailed message ->
                Ui.errorBanner message

            Loading ->
                Element.none
        , bodyView device model
        ]


bodyView : Device -> Model -> Element Msg
bodyView device model =
    case model of
        Loaded loaded ->
            Ui.listCard
                { rows = List.map (foodRow device loaded.action) loaded.foods
                , createButton = Ui.ghostButton "+ Create Food" CreateCustomFoodClicked
                }

        LoadFailed _ ->
            Element.none

        Loading ->
            Ui.loading "Loading foods..."


foodRow : Device -> ActionState -> ProductDetail -> Element Msg
foodRow device action food =
    let
        macroDot : Element Msg
        macroDot =
            View.Nutrients.macroDot
                (food.nutritionSummary.per100g |> Nutrition.summaryToNutrients)
    in
    Ui.listRow
        { onSelect = OpenFoodClicked food.id
        , leading = [ macroDot ]
        , title = Ui.truncatedHeader device food.name
        , subtitle =
            [ Ui.mutedText (foodSummaryText food)
            , Ui.chips food.categories
            ]
        , trailing =
            [ Ui.iconButton { label = "✎", title = "Edit", onPress = EditFoodClicked food.id }
            , Ui.dangerIconButton
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
