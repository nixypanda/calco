module Page.FoodLog.Entry exposing
    ( ItemDetail(..)
    , LoadFailedModel
    , LoadedItem(..)
    , LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , ProductState
    , contentView
    , init
    , loadId
    , modalView
    , modelId
    , nutrientsForDisplay
    , update
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (UpdateLogRequest)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients
import View.Product



-- MODEL


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed LoadFailedModel


type alias LoadingModel =
    { logId : String, log : Maybe FoodLog, units : Maybe (List UnitItem) }


type alias LoadedModel =
    { logId : String
    , log : FoodLog
    , item : LoadedItem
    , units : List UnitItem
    , form : FoodLogForm.Model
    , delete : DeleteState
    }


type LoadedItem
    = ProductItem ProductState
    | MealItem FoodLog.LogItem
    | AdHocItem FoodLog.LogItem


type ItemDetail a
    = DetailLoading FoodLog.LogItem
    | DetailLoaded a
    | DetailUnavailable FoodLog.LogItem


type alias ProductState =
    ItemDetail ProductDetail


isSubmitting : FoodLogForm.Model -> Bool
isSubmitting form =
    form.submitState == FoodLogForm.SubmitSubmitting


type alias LoadFailedModel =
    { logId : String, error : String }


init : String -> ( Model, OutMsg )
init logId =
    ( Loading { logId = logId, log = Nothing, units = Nothing }, RequestInitialData logId )



-- UPDATE


type Msg
    = LogLoaded String (Result Client.ApiError FoodLog)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | ProductDetailLoaded (Result Client.ApiError ProductDetail)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | UpdateCompleted (Result Client.ApiError FoodLog)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())


modelId : Model -> String
modelId model =
    case model of
        Loading loading ->
            loading.logId

        Loaded loaded ->
            loaded.logId

        LoadFailed failed ->
            failed.logId


loadId : Msg -> Maybe String
loadId msg =
    case msg of
        LogLoaded logId _ ->
            Just logId

        _ ->
            Nothing


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestUpdateLog String UpdateLogRequest
    | RequestDeleteLog String
    | LogUpdated LocalDate
    | LogDeleted LocalDate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LogLoaded incomingId result ->
            if modelId model /= incomingId then
                ( model, Cmd.none, NoOp )

            else
                case result of
                    Ok log ->
                        ( setLoadedLog log model, Cmd.none, itemResolutionOutMsg log )

                    Err error ->
                        loadFailure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( setLoadedUnits response.items model, Cmd.none, NoOp )

                Err error ->
                    loadFailure error model

        ProductDetailLoaded result ->
            ( updateLoadedItem (applyProductDetail result) model, Cmd.none, NoOp )

        FormMsg subMsg ->
            case model of
                Loaded loaded ->
                    ( Loaded { loaded | form = FoodLogForm.update subMsg loaded.form }
                    , Cmd.none
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model of
                Loaded loaded ->
                    if not (isSubmitting loaded.form) then
                        submitLoaded loaded

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        UpdateCompleted result ->
            case result of
                Ok log ->
                    ( updateLoadedLog log model, Cmd.none, LogUpdated log.logDate )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message current -> applyLoadedError message current
                        }
                        error
                        model

        DeleteClicked ->
            case model of
                Loaded loaded ->
                    if not (isSubmitting loaded.form) then
                        ( Loaded { loaded | delete = DeleteConfirming }, Cmd.none, NoOp )

                    else
                        ( model, Cmd.none, NoOp )

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
                    if not (isSubmitting loaded.form) then
                        case loaded.delete of
                            DeleteConfirming ->
                                ( Loaded
                                    { loaded | delete = Deleting }
                                , Cmd.none
                                , RequestDeleteLog loaded.logId
                                )

                            DeleteFailed _ ->
                                ( Loaded
                                    { loaded | delete = Deleting }
                                , Cmd.none
                                , RequestDeleteLog loaded.logId
                                )

                            _ ->
                                ( model, Cmd.none, NoOp )

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted result ->
            case model of
                Loaded loaded ->
                    if loaded.delete == Deleting then
                        case result of
                            Ok _ ->
                                ( model
                                , Cmd.none
                                , LogDeleted loaded.log.logDate (DiaryDay Nothing Nothing)
                                )

                            Err error ->
                                Client.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyLoadedDeleteError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


submitLoaded : LoadedModel -> ( Model, Cmd Msg, OutMsg )
submitLoaded loaded =
    case FoodLogForm.createUpdateLogRequest loaded.form of
        Ok request ->
            ( Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState FoodLogForm.SubmitSubmitting loaded.form
                }
            , Cmd.none
            , RequestUpdateLog loaded.logId request
            )

        Err FoodLogForm.AmountRequired ->
            ( Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState
                            (FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage)
                            loaded.form
                }
            , Cmd.none
            , NoOp
            )

        Err FoodLogForm.InvalidDate ->
            ( Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState
                            (FoodLogForm.SubmitFailed FoodLogForm.InvalidDateMessage)
                            loaded.form
                }
            , Cmd.none
            , NoOp
            )


setLoadedLog : FoodLog -> Model -> Model
setLoadedLog log model =
    case model of
        Loading loading ->
            completeLoading { loading | log = Just log }

        Loaded loaded ->
            Loaded
                { loaded
                    | log = log
                    , item = nextLoadedItem loaded log
                    , form = FoodLogForm.initLogFormFromLog log
                    , delete = DeleteIdle
                }

        LoadFailed _ ->
            model


setLoadedUnits : List UnitItem -> Model -> Model
setLoadedUnits units model =
    case model of
        Loading loading ->
            completeLoading { loading | units = Just units }

        Loaded loaded ->
            Loaded { loaded | units = units, delete = DeleteIdle }

        LoadFailed _ ->
            model


completeLoading : LoadingModel -> Model
completeLoading loading =
    case ( loading.log, loading.units ) of
        ( Just log, Just units ) ->
            Loaded
                { logId = loading.logId
                , log = log
                , item = initialLoadedItem log
                , units = units
                , form = FoodLogForm.initLogFormFromLog log
                , delete = DeleteIdle
                }

        _ ->
            Loading loading


updateLoadedLog : FoodLog -> Model -> Model
updateLoadedLog log model =
    case model of
        Loaded loaded ->
            Loaded
                { loaded
                    | log = log
                    , item = nextLoadedItem loaded log
                    , form = FoodLogForm.initLogFormFromLog log
                    , delete = DeleteIdle
                }

        _ ->
            model


nextLoadedItem : LoadedModel -> FoodLog -> LoadedItem
nextLoadedItem loaded log =
    if sameLogItem loaded.log.item log.item then
        loaded.item

    else
        initialLoadedItem log


sameLogItem : FoodLog.LogItem -> FoodLog.LogItem -> Bool
sameLogItem left right =
    left == right


initialLoadedItem : FoodLog -> LoadedItem
initialLoadedItem log =
    case log.item of
        FoodLog.ProductLogItem _ ->
            ProductItem (DetailLoading log.item)

        FoodLog.MealLogItem _ ->
            MealItem log.item

        FoodLog.AdHocLogItem _ ->
            AdHocItem log.item


updateLoadedItem : (LoadedItem -> LoadedItem) -> Model -> Model
updateLoadedItem transform model =
    case model of
        Loaded loaded ->
            Loaded { loaded | item = transform loaded.item }

        _ ->
            model


applyProductDetail : Result Client.ApiError ProductDetail -> LoadedItem -> LoadedItem
applyProductDetail result item =
    case item of
        ProductItem productState ->
            case result of
                Ok food ->
                    if productStateId productState == food.id then
                        ProductItem (DetailLoaded food)

                    else
                        item

                Err _ ->
                    ProductItem (DetailUnavailable (productStateItem productState))

        _ ->
            item


productStateId : ProductState -> String
productStateId state =
    productStateItem state |> FoodLog.itemRef |> Maybe.map .id |> Maybe.withDefault ""


productStateItem : ProductState -> FoodLog.LogItem
productStateItem state =
    case state of
        DetailLoading item ->
            item

        DetailLoaded food ->
            FoodLog.ProductLogItem { id = food.id, name = food.name, brand = food.brand }

        DetailUnavailable item ->
            item


applyLoadedError : String -> Model -> Model
applyLoadedError message model =
    case model of
        Loaded loaded ->
            Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState
                            (FoodLogForm.SubmitFailed (FoodLogForm.RequestFailed message))
                            loaded.form
                    , delete = DeleteIdle
                }

        _ ->
            model


applyLoadedDeleteError : String -> Model -> Model
applyLoadedDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | delete = DeleteFailed message }

        _ ->
            model


itemResolutionOutMsg : FoodLog -> OutMsg
itemResolutionOutMsg log =
    case log.item of
        FoodLog.ProductLogItem product ->
            RequestProductDetail product.id

        -- Products need servings, nutrients and allowed units the log lacks. A
        -- meal log already carries everything its view renders.
        FoodLog.MealLogItem _ ->
            NoOp

        FoodLog.AdHocLogItem _ ->
            NoOp


loadFailure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
loadFailure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError =
            \message current -> LoadFailed { logId = modelLogId current, error = message }
        }


modelLogId : Model -> String
modelLogId model =
    case model of
        Loading loading ->
            loading.logId

        Loaded loaded ->
            loaded.logId

        LoadFailed failed ->
            failed.logId



-- VIEW


contentView : Env -> Model -> Element Msg
contentView env model =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ case model of
            LoadFailed failed ->
                Feedback.errorBanner env.theme failed.error

            Loading _ ->
                Element.none

            Loaded _ ->
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
            foodLogEntrySkeleton env.theme


loadedView : Env -> LoadedModel -> Element Msg
loadedView env model =
    let
        maybeFood : Maybe ProductDetail
        maybeFood =
            case model.item of
                ProductItem (DetailLoaded food) ->
                    Just food

                ProductItem (DetailLoading _) ->
                    Nothing

                ProductItem (DetailUnavailable _) ->
                    Nothing

                MealItem _ ->
                    Nothing

                AdHocItem _ ->
                    Nothing

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            nutrientsForDisplay model.item model.log model.form

        categories : List (Element Msg)
        categories =
            itemCategories env.theme model.item
    in
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Surface.panel env.theme
            { header = Just (itemHeaderElement env model)
            , sections =
                (if List.isEmpty categories then
                    []

                 else
                    [ { title = Nothing, body = categories } ]
                )
                    ++ [ { title =
                            Just
                                (Typography.subsectionTitle
                                    env.theme
                                    (I18n.t env.language TidFoodShowPortion)
                                )
                         , body =
                            List.map (Element.map FormMsg)
                                (FoodLogForm.fields
                                    env
                                    maybeFood
                                    (unitsForItem model)
                                    model.form
                                )
                         }
                       ]
            , footer = Just (detailActionsView env model)
            }
        , View.Nutrients.nutritionCard env nutrients
        ]


submitState : LoadedModel -> Button.SubmitState
submitState model =
    if isSubmitting model.form then
        Button.Submitting

    else if formHasChanges model.log model.form then
        Button.Idle

    else
        Button.Disabled


formHasChanges : FoodLog -> FoodLogForm.Model -> Bool
formHasChanges log form =
    let
        original : FoodLogForm.Model
        original =
            FoodLogForm.initLogFormFromLog log
    in
    (form.amount /= original.amount)
        || (form.unit /= original.unit)
        || (form.mealSlot /= original.mealSlot)
        || (form.notes /= original.notes)


nutrientsForDisplay :
    LoadedItem
    -> FoodLog
    -> FoodLogForm.Model
    -> List Nutrition.NutrientAmount
nutrientsForDisplay item log form =
    let
        currentQuantity : { amount : String, unit : String }
        currentQuantity =
            { amount = form.amount, unit = form.unit }

        savedSnapshot : List Nutrition.NutrientAmount
        savedSnapshot =
            Nutrition.scaledSnapshotForQuantity
                log.quantity
                currentQuantity
                log.nutrients
                |> Maybe.withDefault log.nutrients
    in
    case item of
        ProductItem (DetailLoaded food) ->
            Nutrition.nutrientsForQuantity
                currentQuantity
                food.servings
                food.nutrients
                |> Maybe.withDefault savedSnapshot

        ProductItem (DetailLoading _) ->
            savedSnapshot

        ProductItem (DetailUnavailable _) ->
            savedSnapshot

        MealItem _ ->
            savedSnapshot

        AdHocItem _ ->
            savedSnapshot


itemHeaderElement : Env -> LoadedModel -> Element Msg
itemHeaderElement env model =
    UiPage.pageHeader env.theme
        { leading = Just (View.Nutrients.macroDot env model.log.nutrients)
        , title = itemTitle env.theme model.item
        , subtitle = Just (metaSubtitle env model.item model.log)
        , actions = []
        }


itemCategories : Theme -> LoadedItem -> List (Element Msg)
itemCategories theme item =
    case item of
        ProductItem (DetailLoaded food) ->
            if List.isEmpty food.categories then
                []

            else
                [ Element.row
                    [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                    [ View.Product.macroDotGhost, Chip.chips theme food.categories ]
                ]

        ProductItem (DetailLoading _) ->
            []

        ProductItem (DetailUnavailable _) ->
            []

        MealItem _ ->
            []

        AdHocItem _ ->
            []


itemTitle : Theme -> LoadedItem -> Element msg
itemTitle theme item =
    case item of
        ProductItem productState ->
            case productState of
                DetailLoading _ ->
                    Skeleton.bar theme

                DetailLoaded food ->
                    Typography.truncatedHeader theme food.name

                DetailUnavailable fallback ->
                    Element.text (FoodLog.itemName fallback)

        MealItem meal ->
            Typography.truncatedHeader theme (FoodLog.itemName meal)

        AdHocItem adHoc ->
            Typography.truncatedHeader theme (FoodLog.itemName adHoc)


metaSubtitle : Env -> LoadedItem -> FoodLog -> UiPage.PageHeaderSubtitle
metaSubtitle env item log =
    let
        fallback : UiPage.PageHeaderSubtitle
        fallback =
            UiPage.SubtitleText
                (Text.dotSeparated
                    [ FoodLog.itemBrand log.item
                    , Just
                        (I18n.t env.language
                            (TidFoodLogLogged (LocalDate.display env.language log.logDate))
                        )
                    ]
                )
    in
    case item of
        ProductItem (DetailLoaded food) ->
            let
                productMeta : List String
                productMeta =
                    [ food.brand ] |> List.filterMap identity

                loggedMeta : String
                loggedMeta =
                    I18n.t env.language
                        (TidFoodLogLogged (LocalDate.display env.language log.logDate))
            in
            if UiCommon.isSmall env.device then
                UiPage.SubtitleMetaLines
                    { lines =
                        [ productMeta, [ loggedMeta ] ] |> List.filter (not << List.isEmpty)
                    , separator = " ⋅ "
                    }

            else
                UiPage.SubtitleMeta { items = productMeta ++ [ loggedMeta ], separator = " ⋅ " }

        ProductItem (DetailLoading _) ->
            fallback

        ProductItem (DetailUnavailable _) ->
            fallback

        MealItem _ ->
            fallback

        AdHocItem _ ->
            fallback


unitsForItem : LoadedModel -> List UnitItem
unitsForItem model =
    case model.log.item of
        FoodLog.AdHocLogItem _ ->
            List.filter (\unit -> unit.code == model.log.quantity.unit) model.units

        _ ->
            model.units


detailActionsView : Env -> LoadedModel -> Element Msg
detailActionsView env model =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
        [ Element.row
            [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
            [ Element.el [ Element.width Element.fill ]
                (Button.textButton env.device
                    env.theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t env.language TidCommonSave
                    , onPress = SubmitClicked
                    , submitState = Just (submitState model)
                    , submittingLabel = Just (I18n.t env.language TidCommonSaving)
                    , trailing = Nothing
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Button.bottomActionButtons env.device
                    env.theme
                    [ { label = I18n.t env.language TidFoodLogDelete
                      , onPress = DeleteClicked
                      , tone = Button.Danger
                      }
                    ]
                )
            ]
        ]


deleteModalView : Env -> LoadedModel -> Maybe (Element Msg)
deleteModalView env loaded =
    View.DeleteModal.deleteModalView env
        { title = I18n.t env.language TidFoodLogDeleteConfirmTitle
        , description = I18n.t env.language TidFoodLogDeleteConfirmDescription
        , confirmLabel = I18n.t env.language TidCustomFoodConfirmDelete
        , pendingLabel = I18n.t env.language TidCustomFoodDeleting
        , onCancel = CancelDeleteClicked
        , onConfirm = ConfirmDeleteClicked
        }
        loaded.delete


foodLogEntrySkeleton : Theme -> Element Msg
foodLogEntrySkeleton theme =
    Element.column
        [ Element.width Element.fill, Element.spacing DesignTokens.space16 ]
        [ Skeleton.card theme { rows = 2 }
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.button theme
        , Skeleton.card theme { rows = 3 }
        ]
