module Page.Food.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , contentView
    , foodNutrientsForDisplay
    , init
    , loadId
    , modelId
    , update
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest, RecentItemsResponse)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog exposing (FoodLog)
import Data.LocalContext exposing (LocalContext)
import Data.MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Skeleton as Skeleton
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography
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
    , lookupNote : Maybe String
    }


type alias LoadedModel =
    { productId : String
    , logDate : Maybe String
    , mealSlot : Maybe MealSlot
    , food : ProductDetail
    , units : List UnitItem
    , form : FoodLogForm.Model
    , lastUsedDefault : Maybe Nutrition.Quantity
    , lookupNote : Maybe String
    }


isSubmitting : FoodLogForm.Model -> Bool
isSubmitting form =
    form.submitState == FoodLogForm.SubmitSubmitting


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestLocalContext
    | RequestCreateLog CreateLogRequest
    | LogCreated FoodLog Route
    | SessionExpired


init : String -> Maybe String -> Maybe MealSlot -> Maybe String -> ( Model, OutMsg )
init productId logDate mealSlot lookupNote =
    ( Loading
        { productId = productId
        , logDate = logDate
        , mealSlot = mealSlot
        , food = Nothing
        , units = Nothing
        , lastUsedDefault = Nothing
        , lookupNote = lookupNote
        }
    , RequestInitialData productId
    )



-- UPDATE


type Msg
    = FoodLoaded String (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | LastUsedLoaded String (Result Client.ApiError RecentItemsResponse)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | LocalContextReceived LocalContext
    | LogCompleted (Result Client.ApiError FoodLog)


modelId : Model -> Maybe String
modelId model =
    case model of
        Loading loading ->
            Just loading.productId

        Loaded loaded ->
            Just loaded.productId

        LoadFailed _ ->
            Nothing


loadId : Msg -> Maybe String
loadId msg =
    case msg of
        FoodLoaded productId _ ->
            Just productId

        LastUsedLoaded productId _ ->
            Just productId

        _ ->
            Nothing


isCurrent : String -> Model -> Bool
isCurrent incomingId model =
    modelId model == Just incomingId


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FoodLoaded incomingId result ->
            if not (isCurrent incomingId model) then
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

        LastUsedLoaded incomingId result ->
            if not (isCurrent incomingId model) then
                ( model, Cmd.none, NoOp )

            else
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
                    if isSubmitting loaded.form then
                        ( model, Cmd.none, NoOp )

                    else if String.trim loaded.form.amount == "" then
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
                                        FoodLogForm.SubmitSubmitting
                                        loaded.form
                            }
                        , Cmd.none
                        , RequestLocalContext
                        )

                _ ->
                    ( model, Cmd.none, NoOp )

        LocalContextReceived context ->
            case model of
                Loaded loaded ->
                    if isSubmitting loaded.form then
                        createLogFromLocalContext context loaded

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )

        LogCompleted result ->
            case model of
                Loaded loaded ->
                    if isSubmitting loaded.form then
                        case result of
                            Ok log ->
                                ( model
                                , Cmd.none
                                , LogCreated log
                                    (FoodSearch loaded.logDate loaded.mealSlot)
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
    LocalContext
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
                , lastUsedDefault = loading.lastUsedDefault
                , lookupNote = loading.lookupNote
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
                }

        _ ->
            model



-- VIEW


contentView :
    { model : Model, env : Env }
    -> Element Msg
contentView { model, env } =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ case model of
            LoadFailed message ->
                Feedback.errorBanner env.theme message

            Loaded _ ->
                Element.none

            Loading _ ->
                Element.none
        , bodyView env model
        ]


bodyView : Env -> Model -> Element Msg
bodyView env model =
    case model of
        Loaded loaded ->
            loadedView env loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            foodShowSkeleton env.theme


loadedView : Env -> LoadedModel -> Element Msg
loadedView env loaded =
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

        categories : List (Element Msg)
        categories =
            View.Product.foodCategories env.theme food
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Maybe.withDefault Element.none
            (Maybe.map (Feedback.infoBanner env.theme) loaded.lookupNote)
        , Surface.panel env.theme
            { header =
                Just (View.Product.foodHeaderElement env food [])
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
                                    (Just food)
                                    loaded.units
                                    form
                                )
                         }
                       ]
            , footer = Just (submitActionView env form)
            }
        , View.Nutrients.nutritionCard env nutrients
        ]


submitActionView : Env -> FoodLogForm.Model -> Element Msg
submitActionView env form =
    Button.textButton env.device
        env.theme
        { tone = Button.Primary
        , width = Button.FullWidth
        , label = I18n.t env.language TidTitleLogFood
        , onPress = SubmitClicked
        , submitState = Just (Button.submittingOrIdle (isSubmitting form))
        , submittingLabel = Just (I18n.t env.language TidFoodShowLogging)
        , trailing = Nothing
        }


foodNutrientsForDisplay : ProductDetail -> FoodLogForm.Model -> List Nutrition.NutrientAmount
foodNutrientsForDisplay food form =
    Nutrition.nutrientsForQuantity
        { amount = form.amount, unit = form.unit }
        food.servings
        food.nutrients
        |> Maybe.withDefault (View.Product.foodNutrientsPer100g food)


foodShowSkeleton : Theme -> Element msg
foodShowSkeleton theme =
    Element.column
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space16
        ]
        [ Skeleton.barCustom theme
            { width = Element.fill, height = 120 }
        , Skeleton.barCustom theme
            { width = Element.fillPortion 2, height = 16 }
        , Skeleton.barCustom theme
            { width = Element.fillPortion 3, height = 12 }
        , Skeleton.input theme
        , Skeleton.button theme
        , Skeleton.card theme { rows = 3 }
        ]
