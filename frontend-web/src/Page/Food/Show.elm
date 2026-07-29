module Page.Food.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , RequestState(..)
    , contentView
    , foodNutrientsForDisplay
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest, RecentItemsResponse)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Html.Attributes
import Page.FoodLog.Form as FoodLogForm
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import View.Nutrients
import View.Product



-- MODEL


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String


type alias LoadingModel =
    { productId : String
    , logDate : Maybe String
    , mealSlot : Maybe MealSlot
    , food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    , lastUsedDefault : Maybe Nutrition.Quantity
    }


type alias LoadedModel =
    { productId : String
    , logDate : Maybe String
    , mealSlot : Maybe MealSlot
    , food : ProductDetail
    , units : List UnitItem
    , form : FoodLogForm.Model
    , request : RequestState
    , lastUsedDefault : Maybe Nutrition.Quantity
    }


type RequestState
    = Idle
    | RequestingLocalContext
    | Saving


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestLocalContext
    | RequestCreateLog CreateLogRequest
    | Navigate Route
    | SessionExpired


init : String -> Maybe String -> Maybe MealSlot -> ( Model, OutMsg )
init productId logDate mealSlot =
    ( Loading
        { productId = productId
        , logDate = logDate
        , mealSlot = mealSlot
        , food = Nothing
        , units = Nothing
        , lastUsedDefault = Nothing
        }
    , RequestInitialData productId
    )



-- UPDATE


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | LastUsedLoaded (Result Client.ApiError RecentItemsResponse)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | LocalContextReceived { date : String, timezone : String }
    | LogCompleted (Result Client.ApiError FoodLog)


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

        LastUsedLoaded result ->
            case result of
                Ok response ->
                    ( applyLastUsedDefault
                        (List.head response.items |> Maybe.map .quantity)
                        model
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    if Client.isUnauthorized error then
                        ( model, Cmd.none, SessionExpired )

                    else
                        ( model, Cmd.none, NoOp )

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
                        if String.trim loaded.form.amount == "" then
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

                        else
                            ( Loaded
                                { loaded
                                    | form =
                                        FoodLogForm.setSubmitState
                                            FoodLogForm.SubmitIdle
                                            loaded.form
                                    , request = RequestingLocalContext
                                }
                            , Cmd.none
                            , RequestLocalContext
                            )

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        LocalContextReceived context ->
            case model of
                Loaded loaded ->
                    if loaded.request /= RequestingLocalContext then
                        ( model, Cmd.none, NoOp )

                    else
                        createLogFromLocalContext context loaded

                _ ->
                    ( model, Cmd.none, NoOp )

        LogCompleted result ->
            case model of
                Loaded loaded ->
                    if loaded.request == Saving then
                        case result of
                            Ok _ ->
                                ( model
                                , Cmd.none
                                , Navigate (FoodSearch loaded.logDate loaded.mealSlot)
                                )

                            Err error ->
                                Client.failure
                                    { noOp = NoOp
                                    , sessionExpired = SessionExpired
                                    , applyError =
                                        \message current ->
                                            applyLoadedError message current
                                    }
                                    error
                                    model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


createLogFromLocalContext :
    { date : String, timezone : String }
    -> LoadedModel
    -> ( Model, Cmd Msg, OutMsg )
createLogFromLocalContext context loaded =
    let
        logDate : String
        logDate =
            Maybe.withDefault context.date loaded.logDate
    in
    case
        FoodLogForm.createProductLogRequest logDate
            (Just context.timezone)
            loaded.productId
            loaded.form
    of
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
            , RequestCreateLog request
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
                    , request = Idle
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
                    , request = Idle
                }
            , Cmd.none
            , NoOp
            )


setLoadedFood : ProductDetail -> Model -> Model
setLoadedFood food model =
    case model of
        Loading loading ->
            completeLoading { loading | food = Just food }

        Loaded loaded ->
            Loaded
                { loaded
                    | food = food
                    , form =
                        formWithLastUsedDefault
                            loaded.lastUsedDefault
                            (FoodLogForm.initLogFormFromFood loaded.mealSlot food)
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
            Loaded { loaded | units = units }

        LoadFailed _ ->
            model


completeLoading : LoadingModel -> Model
completeLoading loading =
    case ( loading.food, loading.units ) of
        ( Just food, Just units ) ->
            Loaded
                { productId = loading.productId
                , logDate = loading.logDate
                , mealSlot = loading.mealSlot
                , food = food
                , units = units
                , form =
                    formWithLastUsedDefault
                        loading.lastUsedDefault
                        (FoodLogForm.initLogFormFromFood loading.mealSlot food)
                , request = Idle
                , lastUsedDefault = loading.lastUsedDefault
                }

        _ ->
            Loading loading


applyLastUsedDefault : Maybe Nutrition.Quantity -> Model -> Model
applyLastUsedDefault maybeQuantity model =
    case maybeQuantity of
        Nothing ->
            model

        Just quantity ->
            case model of
                Loading loading ->
                    Loading { loading | lastUsedDefault = Just quantity }

                Loaded loaded ->
                    Loaded
                        { loaded
                            | lastUsedDefault = Just quantity
                            , form = FoodLogForm.applyQuantityDefault quantity loaded.form
                        }

                LoadFailed _ ->
                    model


formWithLastUsedDefault :
    Maybe Nutrition.Quantity
    -> FoodLogForm.Model
    -> FoodLogForm.Model
formWithLastUsedDefault maybeQuantity form =
    case maybeQuantity of
        Just quantity ->
            FoodLogForm.applyQuantityDefault quantity form

        Nothing ->
            form


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


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
                }

        _ ->
            model



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    Ui.pageContainer device
        [ contentView { model = model, device = device, theme = theme } ]


contentView : { model : Model, device : Device, theme : Theme } -> Element Msg
contentView { model, device, theme } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ case model of
            LoadFailed message ->
                Ui.errorBanner theme message

            Loaded _ ->
                Element.none

            Loading _ ->
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

        form : FoodLogForm.Model
        form =
            loaded.form

        nutrients : List Nutrition.NutrientAmount
        nutrients =
            foodNutrientsForDisplay food form
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ View.Product.foodHeader theme food []
        , Element.map FormMsg (FoodLogForm.view theme device (Just food) loaded.units form)
        , submitActionView theme device loaded.request
        , View.Nutrients.nutritionCard theme device nutrients
        ]


submitActionView : Theme -> Device -> RequestState -> Element Msg
submitActionView theme device requestState =
    Ui.primarySubmitButton device
        theme
        { state = Ui.submittingOrIdle (requestState == Saving)
        , idleLabel = "Log Food"
        , submittingLabel = "Logging..."
        , onPress = SubmitClicked
        }
        |> (\button ->
                if Ui.isSmall device then
                    Element.el
                        [ Element.width Element.fill
                        , Element.htmlAttribute
                            (Html.Attributes.style "padding-bottom"
                                "calc(14px + env(safe-area-inset-bottom))"
                            )
                        ]
                        button

                else
                    button
           )


foodNutrientsForDisplay : ProductDetail -> FoodLogForm.Model -> List Nutrition.NutrientAmount
foodNutrientsForDisplay food form =
    Nutrition.nutrientsForQuantity
        { amount = form.amount, unit = form.unit }
        food.servings
        food.nutrients
        |> Maybe.withDefault (View.Product.foodNutrientsPer100g food)
