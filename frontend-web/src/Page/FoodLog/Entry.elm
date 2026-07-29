module Page.FoodLog.Entry exposing
    ( ItemDetail(..)
    , LoadFailedModel
    , LoadedItem(..)
    , LoadedModel
    , LoadingModel
    , MealState
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , ProductState
    , RequestState(..)
    , init
    , modalView
    , nutrientsForDisplay
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (UpdateLogRequest)
import Api.Meals exposing (MealName)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef exposing (ItemType(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Lib.Date as LocalDate
import Page.FoodLog.Form as FoodLogForm
import Ui
import Ui.DesignTokens as DesignTokens
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
    , request : RequestState
    , delete : DeleteState
    }


type LoadedItem
    = ProductItem ProductState
    | MealItem MealState


type ItemDetail a
    = DetailLoading Data.FoodLog.LogItem
    | DetailLoaded a
    | DetailUnavailable Data.FoodLog.LogItem


type alias ProductState =
    ItemDetail ProductDetail


type alias MealState =
    ItemDetail MealName


type RequestState
    = Idle
    | Saving


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
    = LogLoaded (Result Client.ApiError FoodLog)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | ProductDetailLoaded (Result Client.ApiError ProductDetail)
    | MealNameLoaded (Result Client.ApiError MealName)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | UpdateCompleted (Result Client.ApiError FoodLog)
    | DeleteClicked
    | CancelDeleteClicked
    | ConfirmDeleteClicked
    | DeleteCompleted (Result Client.ApiError ())


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestMealName String
    | RequestUpdateLog String UpdateLogRequest
    | RequestDeleteLog String
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        LogLoaded result ->
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

        MealNameLoaded result ->
            ( updateLoadedItem (applyMealName result) model, Cmd.none, NoOp )

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
                    if loaded.request == Idle then
                        submitLoaded loaded

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        UpdateCompleted result ->
            case result of
                Ok log ->
                    ( updateLoadedLog log model, Cmd.none, NoOp )

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
                    if loaded.request == Idle then
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
                    if loaded.request == Idle then
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
                                ( model, Cmd.none, Navigate (DiaryDay Nothing Nothing) )

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
                    , request = Saving
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
                    , request = Idle
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
                , request = Idle
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
                    , request = Idle
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


sameLogItem : Data.FoodLog.LogItem -> Data.FoodLog.LogItem -> Bool
sameLogItem left right =
    left.itemType == right.itemType && left.id == right.id


initialLoadedItem : FoodLog -> LoadedItem
initialLoadedItem log =
    case log.item.itemType of
        Product ->
            ProductItem (DetailLoading log.item)

        Meal ->
            MealItem (DetailLoading log.item)


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


applyMealName : Result Client.ApiError MealName -> LoadedItem -> LoadedItem
applyMealName result item =
    case item of
        MealItem mealState ->
            case result of
                Ok meal ->
                    if mealStateId mealState == meal.id then
                        MealItem (DetailLoaded meal)

                    else
                        item

                Err _ ->
                    MealItem (DetailUnavailable (mealStateItem mealState))

        _ ->
            item


productStateId : ProductState -> String
productStateId state =
    (productStateItem state).id


productStateItem : ProductState -> Data.FoodLog.LogItem
productStateItem state =
    case state of
        DetailLoading item ->
            item

        DetailLoaded food ->
            { itemType = Product
            , id = food.id
            , name = food.name
            , brand = food.brand
            }

        DetailUnavailable item ->
            item


mealStateId : MealState -> String
mealStateId state =
    (mealStateItem state).id


mealStateItem : MealState -> Data.FoodLog.LogItem
mealStateItem state =
    case state of
        DetailLoading item ->
            item

        DetailLoaded meal ->
            { itemType = Meal
            , id = meal.id
            , name = meal.name
            , brand = Nothing
            }

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
                    , request = Idle
                    , delete = DeleteIdle
                }

        _ ->
            model


applyLoadedDeleteError : String -> Model -> Model
applyLoadedDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | request = Idle, delete = DeleteFailed message }

        _ ->
            model


itemResolutionOutMsg : FoodLog -> OutMsg
itemResolutionOutMsg log =
    case log.item.itemType of
        Product ->
            RequestProductDetail log.item.id

        Meal ->
            RequestMealName log.item.id


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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ case pageError model of
            Just message ->
                Ui.errorBanner theme message

            Nothing ->
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


pageError : Model -> Maybe String
pageError model =
    case model of
        Loading _ ->
            Nothing

        Loaded _ ->
            Nothing

        LoadFailed failed ->
            Just failed.error


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
loadedView theme device model =
    let
        nutrients : List Nutrition.NutrientAmount
        nutrients =
            nutrientsForDisplay (productDetail model.item) model.log model.form
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ itemHeader theme model
        , Element.map FormMsg
            (FoodLogForm.view theme device (productDetail model.item) model.units model.form)
        , detailActionsView theme device model
        , View.Nutrients.nutritionCard theme device nutrients
        ]


submitState : LoadedModel -> Ui.SubmitState
submitState model =
    if model.request == Saving then
        Ui.Submitting

    else if formHasChanges model.log model.form then
        Ui.Idle

    else
        Ui.Disabled


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


itemHeader : Theme -> LoadedModel -> Element Msg
itemHeader theme model =
    let
        maybeFood : Maybe ProductDetail
        maybeFood =
            productDetail model.item
    in
    Ui.card theme
        [ Ui.pageHeader theme
            { leading = Just (View.Nutrients.macroDot theme model.log.nutrients)
            , title = itemTitle theme model.item
            , subtitle = Just (metaSubtitle maybeFood model.log)
            , actions = []
            }
        , case maybeFood of
            Just food ->
                if List.isEmpty food.categories then
                    Element.none

                else
                    Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space12 ]
                        [ View.Product.macroDotGhost, Ui.chips theme food.categories ]

            Nothing ->
                Element.none
        ]


itemTitle : Theme -> LoadedItem -> Element msg
itemTitle theme item =
    case item of
        ProductItem productState ->
            case productState of
                DetailLoading _ ->
                    Ui.skeletonBar theme

                DetailLoaded food ->
                    Typography.truncatedHeader theme food.name

                DetailUnavailable fallback ->
                    Element.text fallback.name

        MealItem mealState ->
            case mealState of
                DetailLoading _ ->
                    Ui.skeletonBar theme

                DetailLoaded meal ->
                    Typography.truncatedHeader theme meal.name

                DetailUnavailable fallback ->
                    Element.text fallback.name


metaSubtitle : Maybe ProductDetail -> FoodLog -> Ui.PageHeaderSubtitle
metaSubtitle maybeFood log =
    case maybeFood of
        Just food ->
            Ui.SubtitleMeta
                { items =
                    [ food.brand
                    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
                    , Just ("Logged " ++ LocalDate.display log.logDate)
                    ]
                        |> List.filterMap identity
                , separator = " ⋅ "
                }

        Nothing ->
            Ui.SubtitleText ("Logged " ++ LocalDate.display log.logDate)


detailActionsView : Theme -> Device -> LoadedModel -> Element Msg
detailActionsView theme device model =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space12
        ]
        [ Element.row
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space12
            ]
            [ Element.el [ Element.width Element.fill ]
                (Ui.primarySubmitButton device
                    theme
                    { state = submitState model
                    , idleLabel = "Save"
                    , submittingLabel = "Saving..."
                    , onPress = SubmitClicked
                    }
                )
            , Element.el [ Element.width Element.fill ]
                (Ui.bottomActionButtons device
                    theme
                    [ { label = "Delete Log"
                      , onPress = DeleteClicked
                      , tone = Ui.DangerAction
                      }
                    ]
                )
            ]
        ]


deleteModalView : Theme -> Device -> LoadedModel -> Maybe (Element Msg)
deleteModalView theme device loaded =
    View.DeleteModal.deleteModalView theme
        device
        { title = "Delete log?"
        , description = "This will permanently remove the log entry."
        , onCancel = CancelDeleteClicked
        , onConfirm = ConfirmDeleteClicked
        }
        loaded.delete
