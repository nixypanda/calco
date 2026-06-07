module Page.Food.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , RequestState(..)
    , customFoodEditRoute
    , foodNutrientsForDisplay
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest)
import Api.Result as ApiResult
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Page.FoodLog.Form as FoodLogForm
import Ui
import View.Nutrients


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String


type alias LoadingModel =
    { productId : String
    , mealSlot : Maybe MealSlot
    , food : Maybe ProductDetail
    , units : Maybe (List UnitItem)
    }


type alias LoadedModel =
    { productId : String
    , mealSlot : Maybe MealSlot
    , food : ProductDetail
    , units : List UnitItem
    , form : FoodLogForm.Model
    , error : Maybe String
    , request : RequestState
    }


type RequestState
    = Idle
    | RequestingLocalContext
    | Saving


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg FoodLogForm.Msg
    | SubmitClicked
    | LocalContextReceived { date : String, timezone : String }
    | LogCompleted (Result Client.ApiError FoodLog)
    | EditCustomFoodClicked


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestLocalContext
    | RequestCreateLog CreateLogRequest
    | Navigate Route
    | SessionExpired


init : String -> Maybe MealSlot -> ( Model, OutMsg )
init productId mealSlot =
    ( Loading
        { productId = productId
        , mealSlot = mealSlot
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
                            let
                                form : FoodLogForm.Model
                                form =
                                    loaded.form
                            in
                            ( Loaded
                                { loaded
                                    | form =
                                        { form | error = Just "Amount is required." }
                                }
                            , Cmd.none
                            , NoOp
                            )

                        else
                            let
                                form : FoodLogForm.Model
                                form =
                                    loaded.form
                            in
                            ( Loaded
                                { loaded
                                    | form = { form | error = Nothing }
                                    , error = Nothing
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
                                ( model, Cmd.none, Navigate (DiaryDay Nothing) )

                            Err error ->
                                ApiResult.failure
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

        EditCustomFoodClicked ->
            case model of
                Loaded loaded ->
                    case customFoodEditRoute loaded.food of
                        Just route ->
                            ( model, Cmd.none, Navigate route )

                        Nothing ->
                            ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


createLogFromLocalContext :
    { date : String, timezone : String }
    -> LoadedModel
    -> ( Model, Cmd Msg, OutMsg )
createLogFromLocalContext context loaded =
    case
        FoodLogForm.createProductLogRequest context.date
            (Just context.timezone)
            loaded.productId
            loaded.form
    of
        Ok request ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form
            in
            ( Loaded
                { loaded
                    | form = { form | submitting = True, error = Nothing }
                    , error = Nothing
                    , request = Saving
                }
            , Cmd.none
            , RequestCreateLog request
            )

        Err FoodLogForm.AmountRequired ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form
            in
            ( Loaded
                { loaded
                    | form =
                        { form
                            | submitting = False
                            , error = Just "Amount is required."
                        }
                    , request = Idle
                }
            , Cmd.none
            , NoOp
            )

        Err FoodLogForm.InvalidDate ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form
            in
            ( Loaded
                { loaded
                    | form =
                        { form
                            | submitting = False
                            , error = Just "Could not read device date."
                        }
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
                    , form = FoodLogForm.initLogFormFromFood loaded.mealSlot food
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
    case ( loading.food, loading.units ) of
        ( Just food, Just units ) ->
            Loaded
                { productId = loading.productId
                , mealSlot = loading.mealSlot
                , food = food
                , units = units
                , form = FoodLogForm.initLogFormFromFood loading.mealSlot food
                , error = Nothing
                , request = Idle
                }

        _ ->
            Loading loading


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


applyLoadedError : String -> Model -> Model
applyLoadedError message model =
    case model of
        Loaded loaded ->
            let
                form : FoodLogForm.Model
                form =
                    loaded.form
            in
            Loaded
                { loaded
                    | form = { form | submitting = False }
                    , error = Just message
                    , request = Idle
                }

        _ ->
            model


customFoodEditRoute : ProductDetail -> Maybe Route
customFoodEditRoute food =
    if food.source == "USER" then
        Just (CustomFoodEdit food.id)

    else
        Nothing


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ case model of
            Loaded loaded ->
                case loaded.error of
                    Just message ->
                        Ui.errorBanner message

                    Nothing ->
                        Element.none

            LoadFailed message ->
                Ui.errorBanner message

            Loading _ ->
                Element.none
        , bodyView device model
        ]


bodyView : Device -> Model -> Element Msg
bodyView device model =
    case model of
        Loaded loaded ->
            loadedView device loaded

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Ui.skeletonCard


loadedView : Device -> LoadedModel -> Element Msg
loadedView device loaded =
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
        , Element.spacing Ui.space16
        ]
        [ foodHeader device food
        , Element.map FormMsg (FoodLogForm.view (Just food) loaded.units form)
        , Ui.cardActions
            [ Ui.primarySubmitButton
                (loaded.request == Saving)
                "Log Food"
                "Logging..."
                SubmitClicked
            ]
        , View.Nutrients.nutritionCard device nutrients
        ]


foodNutrientsForDisplay : ProductDetail -> FoodLogForm.Model -> List Nutrition.NutrientAmount
foodNutrientsForDisplay food form =
    Nutrition.nutrientsForQuantity
        { amount = form.amount, unit = form.unit }
        food.servings
        food.nutrients
        |> Maybe.withDefault (foodNutrientsPer100g food)


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


foodHeader : Device -> ProductDetail -> Element Msg
foodHeader device food =
    let
        editAction : List (Element Msg)
        editAction =
            case customFoodEditRoute food of
                Just _ ->
                    [ Ui.iconButton
                        { label = "✎"
                        , title = "Edit food"
                        , onPress = EditCustomFoodClicked
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
    Ui.card
        [ Ui.pageHeader device
            { leading = Just (View.Nutrients.macroDot macroNutrients)
            , title = Ui.truncatedPageTitle device food.name
            , subtitle = Just (metaText food)
            , actions = editAction
            }
        , if List.isEmpty food.categories then
            Element.none

          else
            Element.row [ Element.width Element.fill, Element.spacing Ui.space12 ]
                [ Ui.macroDotGhost, Ui.chips food.categories ]
        ]


metaText : ProductDetail -> String
metaText food =
    [ food.brand
    , Maybe.map (\grams -> "Serving " ++ grams ++ "g") food.servingSizeG
    ]
        |> Ui.dotSeparated
