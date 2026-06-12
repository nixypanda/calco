module Page.CustomFood.Show exposing
    ( DeleteState(..)
    , LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String


type alias LoadingModel =
    { productId : String
    , food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    }


type alias LoadedModel =
    { productId : String
    , food : ProductDetail
    , units : List UnitItem
    , delete : DeleteState
    }


type DeleteState
    = DeleteIdle
    | DeleteConfirming
    | Deleting
    | DeleteFailed String


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | EditClicked
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestDeleteCustomFood String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( Loading
        { productId = productId
        , food = Nothing
        , units = Nothing
        }
    , RequestInitialData productId
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded result ->
            case result of
                Ok food ->
                    ( setLoadedFood food model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( setLoadedUnits response.items model, Cmd.none, NoOp )

                Err error ->
                    failure error model

        EditClicked ->
            case model of
                Loaded loaded ->
                    case customFoodEditRoute loaded.food of
                        Just route ->
                            ( model, Cmd.none, Navigate route )

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteClicked ->
            case model of
                Loaded loaded ->
                    ( Loaded { loaded | delete = DeleteConfirming }, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        CancelDeleteClicked ->
            case model of
                Loaded loaded ->
                    ( Loaded { loaded | delete = DeleteIdle }, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        ConfirmDeleteClicked ->
            case model of
                Loaded loaded ->
                    case loaded.delete of
                        DeleteConfirming ->
                            ( Loaded { loaded | delete = Deleting }
                            , Cmd.none
                            , RequestDeleteCustomFood loaded.productId
                            )

                        DeleteFailed _ ->
                            ( Loaded { loaded | delete = Deleting }
                            , Cmd.none
                            , RequestDeleteCustomFood loaded.productId
                            )

                        _ ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted result ->
            case model of
                Loaded loaded ->
                    if loaded.delete == Deleting then
                        case result of
                            Ok _ ->
                                ( model, Cmd.none, Navigate CustomFoodList )

                            Err error ->
                                Client.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyDeleteError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


setLoadedFood : ProductDetail -> Model -> Model
setLoadedFood food model =
    case model of
        Loading loading ->
            completeLoading { loading | food = Just food }

        Loaded loaded ->
            Loaded { loaded | food = food, delete = DeleteIdle }

        LoadFailed _ ->
            model


setLoadedUnits : List UnitItem -> Model -> Model
setLoadedUnits units model =
    case model of
        Loading loading ->
            completeLoading { loading | units = Just units }

        Loaded loaded ->
            Loaded { loaded | units = units }

        LoadFailed _ ->
            model


completeLoading : LoadingModel -> Model
completeLoading loading =
    case ( loading.food, loading.units ) of
        ( Just food, Just units ) ->
            Loaded
                { productId = loading.productId
                , food = food
                , units = units
                , delete = DeleteIdle
                }

        _ ->
            Loading loading


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


applyDeleteError : String -> Model -> Model
applyDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | delete = DeleteFailed message }

        _ ->
            model


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            LoadFailed message ->
                Ui.errorBanner theme message

            _ ->
                Element.none
        , bodyView theme device model
        ]


bodyView : Theme -> Device -> Model -> Element Msg
bodyView theme device model =
    case model of
        Loaded loaded ->
            loadedView theme device loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Ui.skeletonLoading theme


loadedView : Theme -> Device -> LoadedModel -> Element Msg
loadedView theme device loaded =
    let
        food : ProductDetail
        food =
            loaded.food

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            foodNutrientsPer100g food
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing Ui.space16
        ]
        [ foodHeader theme device food
        , View.Nutrients.nutritionCard theme device nutrients
        , confirmDeleteView theme device loaded
        ]


foodNutrientsPer100g : ProductDetail -> List Nutrition.NutrientAmount
foodNutrientsPer100g food =
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amount = nutrient.amountPer100g
            , unit = nutrient.unit
            }
        )
        food.nutrients


foodHeader : Theme -> Device -> ProductDetail -> Element Msg
foodHeader theme device food =
    let
        editAction : List (Element Msg)
        editAction =
            case customFoodEditRoute food of
                Just _ ->
                    [ Ui.iconButton device
                        theme
                        { label = "✎"
                        , title = "Edit food"
                        , onPress = EditClicked
                        }
                    , Ui.dangerIconButton device
                        theme
                        { label = "×"
                        , title = "Delete food"
                        , onPress = DeleteClicked
                        }
                    ]

                Nothing ->
                    []

        macroNutrients : List Nutrition.NutrientAmount
        macroNutrients =
            food.nutrients
                |> List.map
                    (\n -> { code = n.code, amount = n.amountPer100g, unit = n.unit })
    in
    Ui.card theme
        [ Ui.pageHeader theme
            { leading = Just (View.Nutrients.macroDot macroNutrients)
            , title = Ui.truncatedHeader theme device food.name
            , subtitle = Just (metaText food)
            , actions = editAction
            }
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.macroDotGhost, Ui.chips theme food.categories ]
        ]


metaText : ProductDetail -> String
metaText food =
    [ food.brand
    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
    ]
        |> Ui.dotSeparated


confirmDeleteView : Theme -> Device -> LoadedModel -> Element Msg
confirmDeleteView theme device loaded =
    case loaded.delete of
        DeleteConfirming ->
            confirmDeleteContent theme device Nothing False

        Deleting ->
            confirmDeleteContent theme device Nothing True

        DeleteFailed message ->
            confirmDeleteContent theme device (Just message) False

        DeleteIdle ->
            Element.none


confirmDeleteContent : Theme -> Device -> Maybe String -> Bool -> Element Msg
confirmDeleteContent theme device maybeError deleting =
    Element.column
        [ Element.spacing Ui.space8
        , Element.padding Ui.space12
        , Background.color theme.dangerBg
        , Border.rounded 16
        ]
        [ Ui.sectionTitle theme device "Delete food?"
        , Ui.maybeErrorBanner theme maybeError
        , Element.row [ Element.spacing Ui.space8 ]
            [ Ui.button device theme "Cancel" CancelDeleteClicked
            , Ui.dangerButton device
                theme
                (if deleting then
                    "Deleting..."

                 else
                    "Confirm Delete"
                )
                ConfirmDeleteClicked
            ]
        ]


customFoodEditRoute : ProductDetail -> Maybe Route
customFoodEditRoute food =
    if food.source == "USER" then
        Just (CustomFoodEdit food.id)

    else
        Nothing
