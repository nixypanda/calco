module Page.CustomFood.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , modalView
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
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients
import View.Product



-- MODEL


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



-- UPDATE


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | EditClicked
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())


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



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case model of
            LoadFailed message ->
                Feedback.errorBanner theme message

            _ ->
                Element.none
        , bodyView theme device model
        ]


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView { model, device, theme } =
    case model of
        Loaded loaded ->
            deleteModalView theme device loaded

        _ ->
            Nothing


bodyView : Theme -> Device -> Model -> Element Msg
bodyView theme device model =
    case model of
        Loaded loaded ->
            loadedView theme device loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            customFoodShowSkeleton theme


loadedView : Theme -> Device -> LoadedModel -> Element Msg
loadedView theme device loaded =
    let
        food : ProductDetail
        food =
            loaded.food

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            View.Product.foodNutrientsPer100g food
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ View.Product.foodHeader theme food []
        , View.Nutrients.nutritionCard theme nutrients
        , bottomActionsView theme device food
        ]


bottomActionsView : Theme -> Device -> ProductDetail -> Element Msg
bottomActionsView theme device food =
    let
        actions : List { label : String, onPress : Msg, tone : Button.ButtonTone }
        actions =
            case customFoodEditRoute food of
                Just _ ->
                    [ { label = "Edit Food", onPress = EditClicked, tone = Button.Primary }
                    , { label = "Delete Food", onPress = DeleteClicked, tone = Button.Danger }
                    ]

                Nothing ->
                    []
    in
    Button.bottomActionButtons device theme actions


deleteModalView : Theme -> Device -> LoadedModel -> Maybe (Element Msg)
deleteModalView theme device loaded =
    View.DeleteModal.deleteModalView theme
        device
        { title = "Delete food?"
        , description = "This will permanently remove the custom food."
        , onCancel = CancelDeleteClicked
        , onConfirm = ConfirmDeleteClicked
        }
        loaded.delete


customFoodEditRoute : ProductDetail -> Maybe Route
customFoodEditRoute food =
    if food.source == "USER" then
        Just (CustomFoodEdit food.id)

    else
        Nothing


customFoodShowSkeleton : Theme -> Element msg
customFoodShowSkeleton theme =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 120)
            , Background.color theme.inputFill
            , Border.rounded DesignTokens.radiusCard
            , Typography.uiClass "ui-skeleton"
            ]
            Element.none
        , Skeleton.bar theme
        , Skeleton.barCustom theme
            { width = Element.fillPortion 2, height = 12 }
        , Skeleton.card theme { rows = 3 }
        , Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Skeleton.button theme
            , Skeleton.button theme
            ]
        ]
