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
import Element exposing (Device, Element)
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Chip as Chip
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
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
    { logId : String
    , log : Maybe FoodLog
    , units : Maybe (List UnitItem)
    }


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
    { logId : String
    , error : String
    }


init : String -> ( Model, OutMsg )
init logId =
    ( Loading
        { logId = logId
        , log = Nothing
        , units = Nothing
        }
    , RequestInitialData logId
    )



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


modelId : Model -> Maybe String
modelId model =
    case model of
        Loading loading ->
            Just loading.logId

        Loaded loaded ->
            Just loaded.logId

        LoadFailed failed ->
            Just failed.logId


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
            if modelId model /= Just incomingId then
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
                                    { loaded
                                        | delete = Deleting
                                    }
                                , Cmd.none
                                , RequestDeleteLog loaded.logId
                                )

                            DeleteFailed _ ->
                                ( Loaded
                                    { loaded
                                        | delete = Deleting
                                    }
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
                        FoodLogForm.setSubmitState
                            FoodLogForm.SubmitSubmitting
                            loaded.form
                }
            , Cmd.none
            , RequestUpdateLog loaded.logId request
            )

        Err FoodLogForm.AmountRequired ->
            ( Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState
                            (FoodLogForm.SubmitFailed
                                FoodLogForm.AmountRequiredMessage
                            )
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
                            (FoodLogForm.SubmitFailed
                                FoodLogForm.InvalidDateMessage
                            )
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


applyProductDetail :
    Result Client.ApiError ProductDetail
    -> LoadedItem
    -> LoadedItem
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
    productStateItem state
        |> FoodLog.itemRef
        |> Maybe.map .id
        |> Maybe.withDefault ""


productStateItem : ProductState -> FoodLog.LogItem
productStateItem state =
    case state of
        DetailLoading item ->
            item

        DetailLoaded food ->
            FoodLog.ProductLogItem
                { id = food.id, name = food.name, brand = food.brand }

        DetailUnavailable item ->
            item


productDetail : LoadedItem -> Maybe ProductDetail
productDetail item =
    case item of
        ProductItem (DetailLoaded food) ->
            Just food

        _ ->
            Nothing


applyLoadedError : String -> Model -> Model
applyLoadedError message model =
    case model of
        Loaded loaded ->
            Loaded
                { loaded
                    | form =
                        FoodLogForm.setSubmitState
                            (FoodLogForm.SubmitFailed
                                (FoodLogForm.RequestFailed message)
                            )
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


contentView :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Element Msg
contentView { model, device, theme, language } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ case pageError model of
            Just message ->
                Feedback.errorBanner theme message

            Nothing ->
                Element.none
        , bodyView theme language device model
        ]


modalView :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Maybe (Element Msg)
modalView { model, device, theme, language } =
    case model of
        Loaded loaded ->
            deleteModalView theme language device loaded

        _ ->
            Nothing


pageError : Model -> Maybe String
pageError model =
    case model of
        Loading _ ->
            Nothing

        Loaded _ ->
            Nothing

        LoadFailed failed ->
            Just failed.error


bodyView : Theme -> Language -> Device -> Model -> Element Msg
bodyView theme language device model =
    case model of
        Loaded loaded ->
            loadedView theme language device loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            foodLogEntrySkeleton theme


loadedView : Theme -> Language -> Device -> LoadedModel -> Element Msg
loadedView theme language device model =
    let
        nutrients : List Nutrition.NutrientAmount
        nutrients =
            nutrientsForDisplay (productDetail model.item) model.log model.form

        categories : List (Element Msg)
        categories =
            itemCategories theme (productDetail model.item)
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Surface.panel theme
            { header = Just (itemHeaderElement theme language device model)
            , sections =
                (if List.isEmpty categories then
                    []

                 else
                    [ { title = Nothing, body = categories } ]
                )
                    ++ [ { title =
                            Just
                                (Typography.subsectionTitle
                                    theme
                                    (I18n.t language TidFoodShowPortion)
                                )
                         , body =
                            List.map (Element.map FormMsg)
                                (FoodLogForm.fields
                                    theme
                                    language
                                    device
                                    (productDetail model.item)
                                    (unitsForItem model)
                                    model.form
                                )
                         }
                       ]
            , footer = Just (detailActionsView theme language device model)
            }
        , View.Nutrients.nutritionCard device theme language nutrients
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
    Maybe ProductDetail
    -> FoodLog
    -> FoodLogForm.Model
    -> List Nutrition.NutrientAmount
nutrientsForDisplay maybeFood log form =
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
    case maybeFood of
        Just food ->
            Nutrition.nutrientsForQuantity
                currentQuantity
                food.servings
                food.nutrients
                |> Maybe.withDefault savedSnapshot

        Nothing ->
            savedSnapshot


itemHeaderElement : Theme -> Language -> Device -> LoadedModel -> Element Msg
itemHeaderElement theme language device model =
    UiPage.pageHeader theme
        { leading = Just (View.Nutrients.macroDot theme language model.log.nutrients)
        , title = itemTitle theme model.item
        , subtitle =
            Just (metaSubtitle language device (productDetail model.item) model.log)
        , actions = []
        }


itemCategories : Theme -> Maybe ProductDetail -> List (Element Msg)
itemCategories theme maybeFood =
    case maybeFood of
        Just food ->
            if List.isEmpty food.categories then
                []

            else
                [ Element.row
                    [ Element.width Element.fill
                    , Element.spacing DesignTokens.space12
                    ]
                    [ View.Product.macroDotGhost, Chip.chips theme food.categories ]
                ]

        Nothing ->
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


metaSubtitle : Language -> Device -> Maybe ProductDetail -> FoodLog -> UiPage.PageHeaderSubtitle
metaSubtitle language device maybeFood log =
    case maybeFood of
        Just food ->
            let
                productMeta : List String
                productMeta =
                    [ food.brand ]
                        |> List.filterMap identity

                loggedMeta : String
                loggedMeta =
                    I18n.t language
                        (TidFoodLogLogged (LocalDate.display language log.logDate))
            in
            if UiCommon.isSmall device then
                UiPage.SubtitleMetaLines
                    { lines =
                        [ productMeta, [ loggedMeta ] ]
                            |> List.filter (not << List.isEmpty)
                    , separator = " ⋅ "
                    }

            else
                UiPage.SubtitleMeta
                    { items = productMeta ++ [ loggedMeta ]
                    , separator = " ⋅ "
                    }

        Nothing ->
            UiPage.SubtitleText
                (Text.dotSeparated
                    [ FoodLog.itemBrand log.item
                    , Just
                        (I18n.t language
                            (TidFoodLogLogged (LocalDate.display language log.logDate))
                        )
                    ]
                )


unitsForItem : LoadedModel -> List UnitItem
unitsForItem model =
    case model.log.item of
        FoodLog.AdHocLogItem _ ->
            List.filter (\unit -> unit.code == model.log.quantity.unit) model.units

        _ ->
            model.units


detailActionsView : Theme -> Language -> Device -> LoadedModel -> Element Msg
detailActionsView theme language device model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space12
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Element.el [ Element.width Element.fill ]
                (Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t language TidCommonSave
                    , onPress = SubmitClicked
                    , submitState = Just (submitState model)
                    , submittingLabel = Just (I18n.t language TidCommonSaving)
                    , trailing = Nothing
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Button.bottomActionButtons device
                    theme
                    [ { label = I18n.t language TidFoodLogDelete
                      , onPress = DeleteClicked
                      , tone = Button.Danger
                      }
                    ]
                )
            ]
        ]


deleteModalView : Theme -> Language -> Device -> LoadedModel -> Maybe (Element Msg)
deleteModalView theme language device loaded =
    View.DeleteModal.deleteModalView theme
        language
        device
        { title = I18n.t language TidFoodLogDeleteConfirmTitle
        , description = I18n.t language TidFoodLogDeleteConfirmDescription
        , confirmLabel = I18n.t language TidCustomFoodConfirmDelete
        , pendingLabel = I18n.t language TidCustomFoodDeleting
        , onCancel = CancelDeleteClicked
        , onConfirm = ConfirmDeleteClicked
        }
        loaded.delete


foodLogEntrySkeleton : Theme -> Element Msg
foodLogEntrySkeleton theme =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Skeleton.card theme { rows = 2 }
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.input theme
        , Skeleton.button theme
        , Skeleton.card theme { rows = 3 }
        ]
