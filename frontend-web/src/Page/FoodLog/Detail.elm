module Page.FoodLog.Detail exposing
    ( LoadFailedModel
    , LoadedItem(..)
    , LoadedModel
    , LoadingModel
    , MealState(..)
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , ProductState(..)
    , RequestState(..)
    , init
    , nutrientsForDisplay
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (UpdateLogRequest)
import Api.Meals exposing (MealName)
import Api.Result as ApiResult
import Data.FoodLog exposing (FoodLog)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Font as Font
import Lib.Date as LocalDate
import Page.Food.Detail
import Ui
import View.FoodLogForm as FoodLogForm
import View.Nutrients


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
    , error : Maybe String
    , request : RequestState
    }


type LoadedItem
    = ProductItem ProductState
    | MealItem MealState
    | UnknownItem Data.FoodLog.LogItem


type ProductState
    = ProductLoading Data.FoodLog.LogItem
    | ProductLoaded ProductDetail
    | ProductUnavailable Data.FoodLog.LogItem


type MealState
    = MealLoading Data.FoodLog.LogItem
    | MealLoaded MealName
    | MealUnavailable Data.FoodLog.LogItem


type RequestState
    = Idle
    | Saving
    | Deleting


type alias LoadFailedModel =
    { logId : String
    , error : String
    }


type Msg
    = LogLoaded (Result Client.ApiError FoodLog)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | ProductDetailLoaded (Result Client.ApiError ProductDetail)
    | MealNameLoaded (Result Client.ApiError MealName)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | UpdateCompleted (Result Client.ApiError FoodLog)
    | DeleteClicked
    | DeleteCompleted (Result Client.ApiError ())
    | EditCustomFoodClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestProductDetail String
    | RequestMealName String
    | RequestUpdateLog String UpdateLogRequest
    | RequestDeleteLog String
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init logId =
    ( Loading
        { logId = logId
        , log = Nothing
        , units = Nothing
        }
    , RequestInitialData logId
    )


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
                    ApiResult.failure
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
                        ( Loaded { loaded | request = Deleting, error = Nothing }
                        , Cmd.none
                        , RequestDeleteLog loaded.logId
                        )

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, Navigate (Diary Nothing) )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message current -> applyLoadedDeleteError message current
                        }
                        error
                        model

        EditCustomFoodClicked ->
            case model of
                Loaded loaded ->
                    case
                        Maybe.andThen Page.Food.Detail.customFoodEditRoute
                            (productDetail loaded.item)
                    of
                        Just route ->
                            ( model, Cmd.none, Navigate route )

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


submitLoaded : LoadedModel -> ( Model, Cmd Msg, OutMsg )
submitLoaded loaded =
    case FoodLogForm.createUpdateLogRequest loaded.form of
        Ok request ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form

                nextForm : FoodLogForm.Model
                nextForm =
                    { form | submitting = True, error = Nothing }
            in
            ( Loaded { loaded | form = nextForm, error = Nothing, request = Saving }
            , Cmd.none
            , RequestUpdateLog loaded.logId request
            )

        Err FoodLogForm.AmountRequired ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form

                nextForm : FoodLogForm.Model
                nextForm =
                    { form | error = Just "Amount is required." }
            in
            ( Loaded { loaded | form = nextForm }
            , Cmd.none
            , NoOp
            )

        Err FoodLogForm.InvalidDate ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form

                nextForm : FoodLogForm.Model
                nextForm =
                    { form | error = Just "Could not read device date." }
            in
            ( Loaded { loaded | form = nextForm }
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
                    , error = Nothing
                    , request = Idle
                }

        LoadFailed _ ->
            model


setLoadedUnits : List UnitItem -> Model -> Model
setLoadedUnits units model =
    case model of
        Loading loading ->
            completeLoading { loading | units = Just units }

        Loaded loaded ->
            Loaded { loaded | units = units, error = Nothing }

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
                , error = Nothing
                , request = Idle
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
                    , error = Nothing
                    , request = Idle
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
        "product" ->
            ProductItem (ProductLoading log.item)

        "meal" ->
            MealItem (MealLoading log.item)

        _ ->
            UnknownItem log.item


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
                        ProductItem (ProductLoaded food)

                    else
                        item

                Err _ ->
                    ProductItem (ProductUnavailable (productStateItem productState))

        _ ->
            item


applyMealName : Result Client.ApiError MealName -> LoadedItem -> LoadedItem
applyMealName result item =
    case item of
        MealItem mealState ->
            case result of
                Ok meal ->
                    if mealStateId mealState == meal.id then
                        MealItem (MealLoaded meal)

                    else
                        item

                Err _ ->
                    MealItem (MealUnavailable (mealStateItem mealState))

        _ ->
            item


productStateId : ProductState -> String
productStateId state =
    (productStateItem state).id


productStateItem : ProductState -> Data.FoodLog.LogItem
productStateItem state =
    case state of
        ProductLoading item ->
            item

        ProductLoaded food ->
            { itemType = "product"
            , id = food.id
            , name = food.name
            , brand = food.brand
            }

        ProductUnavailable item ->
            item


mealStateId : MealState -> String
mealStateId state =
    (mealStateItem state).id


mealStateItem : MealState -> Data.FoodLog.LogItem
mealStateItem state =
    case state of
        MealLoading item ->
            item

        MealLoaded meal ->
            { itemType = "meal"
            , id = meal.id
            , name = meal.name
            , brand = Nothing
            }

        MealUnavailable item ->
            item


productDetail : LoadedItem -> Maybe ProductDetail
productDetail item =
    case item of
        ProductItem (ProductLoaded food) ->
            Just food

        _ ->
            Nothing


applyLoadedError : String -> Model -> Model
applyLoadedError message model =
    case model of
        Loaded loaded ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form

                nextForm : FoodLogForm.Model
                nextForm =
                    { form | submitting = False }
            in
            Loaded
                { loaded
                    | form = nextForm
                    , error = Just message
                    , request = Idle
                }

        _ ->
            model


applyLoadedDeleteError : String -> Model -> Model
applyLoadedDeleteError message model =
    case model of
        Loaded loaded ->
            Loaded { loaded | request = Idle, error = Just message }

        _ ->
            model


itemResolutionOutMsg : FoodLog -> OutMsg
itemResolutionOutMsg log =
    case log.item.itemType of
        "product" ->
            RequestProductDetail log.item.id

        "meal" ->
            RequestMealName log.item.id

        _ ->
            NoOp


loadFailure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
loadFailure =
    ApiResult.failure
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


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ case pageError model of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , bodyView model
        ]


pageError : Model -> Maybe String
pageError model =
    case model of
        Loading _ ->
            Nothing

        Loaded loaded ->
            loaded.error

        LoadFailed failed ->
            Just failed.error


bodyView : Model -> Element Msg
bodyView model =
    case model of
        Loaded loaded ->
            loadedView loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Ui.loading "Loading log..."


loadedView : LoadedModel -> Element Msg
loadedView model =
    let
        nutrients : List Nutrition.NutrientAmount
        nutrients =
            nutrientsForDisplay (productDetail model.item) model.log model.form
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing 16
        ]
        [ itemHeader model
        , Element.map FormMsg
            (FoodLogForm.view (productDetail model.item) model.units model.form)
        , Ui.cardActions
            [ Ui.submitButton (model.request == Saving) "Save" "Saving..." SubmitClicked
            , Ui.dangerButton
                (if model.request == Deleting then
                    "Deleting..."

                 else
                    "Delete"
                )
                DeleteClicked
            ]
        , Ui.card
            [ Ui.sectionHeader "Macro Breakdown"
            , View.Nutrients.macroBreakdownView nutrients
            ]
        , View.Nutrients.nutrientsTable nutrients
        ]


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


itemHeader : LoadedModel -> Element Msg
itemHeader model =
    Ui.card
        [ Element.el [ Ui.heading2, Font.bold ] (Element.text (itemTitle model.item))
        , Ui.mutedText (metaText (productDetail model.item) model.log)
        , case productDetail model.item of
            Just food ->
                if List.isEmpty food.categories then
                    Element.none

                else
                    Element.row [ Element.spacing 4 ] (List.map Ui.badge food.categories)

            Nothing ->
                Element.none
        , case
            Maybe.andThen Page.Food.Detail.customFoodEditRoute
                (productDetail model.item)
          of
            Just _ ->
                Ui.button "Edit food" EditCustomFoodClicked

            Nothing ->
                Element.none
        ]


itemTitle : LoadedItem -> String
itemTitle item =
    case item of
        ProductItem productState ->
            case productState of
                ProductLoading _ ->
                    "Loading food..."

                ProductLoaded food ->
                    food.name

                ProductUnavailable fallback ->
                    fallback.name

        MealItem mealState ->
            case mealState of
                MealLoading _ ->
                    "Loading meal..."

                MealLoaded meal ->
                    meal.name

                MealUnavailable fallback ->
                    fallback.name

        UnknownItem fallback ->
            fallback.name


metaText : Maybe ProductDetail -> FoodLog -> String
metaText maybeFood log =
    case maybeFood of
        Just food ->
            [ food.brand
            , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
            , Just ("Logged " ++ LocalDate.display log.logDate)
            ]
                |> List.filterMap identity
                |> String.join " - "

        Nothing ->
            "Logged " ++ LocalDate.display log.logDate
