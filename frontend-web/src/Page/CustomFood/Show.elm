module Page.CustomFood.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , isBusy
    , loadId
    , modalView
    , modelId
    , skeletonView
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients
import View.Product



-- MODEL


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed { productId : String, message : String }


type alias LoadingModel =
    { productId : String, food : Maybe ProductDetail, units : Maybe (List UnitItem) }


type alias LoadedModel =
    { productId : String, food : ProductDetail, units : List UnitItem, delete : DeleteState }


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestDeleteCustomFood String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( Loading { productId = productId, food = Nothing, units = Nothing }
    , RequestInitialData productId
    )


{-| Only the initial fetch is busy; `LoadFailed` is a settled error state.
-}
isBusy : Model -> Bool
isBusy model =
    case model of
        Loading _ ->
            True

        _ ->
            False



-- UPDATE


type Msg
    = FoodLoaded String (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | EditClicked
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | RetryClicked


modelId : Model -> String
modelId model =
    case model of
        Loading loading ->
            loading.productId

        Loaded loaded ->
            loaded.productId

        LoadFailed failed ->
            failed.productId


loadId : Msg -> Maybe String
loadId msg =
    case msg of
        FoodLoaded productId _ ->
            Just productId

        _ ->
            Nothing


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded incomingId result ->
            if modelId model /= incomingId then
                ( model, Cmd.none, NoOp )

            else
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

        RetryClicked ->
            case model of
                LoadFailed failed ->
                    ( Loading { productId = failed.productId, food = Nothing, units = Nothing }
                    , Cmd.none
                    , RequestInitialData failed.productId
                    )

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
                { productId = loading.productId, food = food, units = units, delete = DeleteIdle }

        _ ->
            Loading loading


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError =
            \message current ->
                case current of
                    Loading loading ->
                        LoadFailed { productId = loading.productId, message = message }

                    Loaded loaded ->
                        LoadFailed { productId = loaded.productId, message = message }

                    LoadFailed _ ->
                        current
        }


applyDeleteError : String -> Model -> Model
applyDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | delete = DeleteFailed message }

        _ ->
            model



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        [ case model of
            LoadFailed failed ->
                Feedback.errorRetry env.theme
                    env.language
                    env.device
                    { message = failed.message, onRetry = RetryClicked }

            _ ->
                Element.none
        , bodyView env model
        ]


modalView : Env -> Model -> Maybe (Element Msg)
modalView env model =
    case model of
        Loaded loaded ->
            deleteModalView env loaded

        _ ->
            Nothing


bodyView : Env -> Model -> Element Msg
bodyView env model =
    case model of
        Loaded loaded ->
            loadedView env loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Skeleton.busy
                { label = I18n.t env.language TidCommonLoading }
                [ skeletonView env ]


loadedView : Env -> LoadedModel -> Element Msg
loadedView env loaded =
    let
        food : ProductDetail
        food =
            loaded.food

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            View.Product.foodNutrientsPer100g food
    in
    Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ View.Product.foodHeader env food []
        , View.Nutrients.nutritionCard env nutrients
        , bottomActionsView env food
        ]


bottomActionsView : Env -> ProductDetail -> Element Msg
bottomActionsView env food =
    let
        actions : List { label : String, onPress : Msg, tone : Button.ButtonTone }
        actions =
            case customFoodEditRoute food of
                Just _ ->
                    [ { label = I18n.t env.language TidTitleEditFood
                      , onPress = EditClicked
                      , tone = Button.Primary
                      }
                    , { label = I18n.t env.language TidCustomFoodDelete
                      , onPress = DeleteClicked
                      , tone = Button.Danger
                      }
                    ]

                Nothing ->
                    []
    in
    Button.bottomActionButtons env.device env.theme actions


deleteModalView : Env -> LoadedModel -> Maybe (Element Msg)
deleteModalView env loaded =
    View.DeleteModal.deleteModalView env
        { title = I18n.t env.language TidCustomFoodDeleteConfirmTitle
        , description = I18n.t env.language TidCustomFoodDeleteConfirmDescription
        , confirmLabel = I18n.t env.language TidCustomFoodConfirmDelete
        , pendingLabel = I18n.t env.language TidCustomFoodDeleting
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


{-| The page body below `UiPage.pageContainer`. The category chip row is an
over-approximation: custom foods may have no categories, in which case the
loaded header section has no body region and the blocks below shrink upward.
The header band itself and the title line stay stable; nutrition and actions
below the variable category row are not part of the contract.
-}
skeletonView : Env -> Element msg
skeletonView env =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Surface.section env.theme
            { header = Just (customFoodHeaderSkeleton env.theme)
            , body = [ Skeleton.categoryChipRow env.theme { count = 3 } ]
            , footer = Nothing
            }
        , View.Nutrients.skeletonCard env
        , Skeleton.bottomActions env.theme { count = 2 }
        ]


{-| Mirrors `View.Product.foodHeader`: a 4x24 macro dot, a 25px title line
(`Typography.truncatedHeader` measures 25px for its 24px paragraph) and a 17px
single-line meta subtitle.
-}
customFoodHeaderSkeleton : Theme -> Element msg
customFoodHeaderSkeleton theme =
    Skeleton.pageHeader
        { leading = Just (Skeleton.dot theme)
        , title = Skeleton.elLine theme { size = 25, width = Element.fill }
        , subtitle = [ Skeleton.elLine theme { size = 17, width = Element.fill } ]
        , actions = []
        }
