module Page.Food.Show exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , RequestState(..)
    , foodNutrientsForDisplay
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, UnitItem)
import Api.Logs exposing (CreateLogRequest)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Html.Attributes
import Page.FoodLog.Form as FoodLogForm
import Ui
import Ui.Theme exposing (Theme)
import View.Nutrients



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
    }


type alias LoadedModel =
    { productId : String
    , logDate : Maybe String
    , mealSlot : Maybe MealSlot
    , food : ProductDetail
    , units : List UnitItem
    , form : FoodLogForm.Model
    , request : RequestState
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
        }
    , RequestInitialData productId
    )



-- UPDATE


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
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
                                ( model, Cmd.none, Navigate (DiaryDay loaded.logDate) )

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
                    , form = FoodLogForm.initLogFormFromFood loaded.mealSlot food
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
                , form = FoodLogForm.initLogFormFromFood loading.mealSlot food
                , request = Idle
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
        , Element.spacing Ui.space16
        ]
        [ foodHeader theme device food
        , Element.map FormMsg (FoodLogForm.view theme device (Just food) loaded.units form)
        , Ui.cardActions
            [ Ui.primarySubmitButton device
                theme
                { state = Ui.submittingOrIdle (loaded.request == Saving)
                , idleLabel = "Log Food"
                , submittingLabel = "Logging..."
                , onPress = SubmitClicked
                }
            ]
            |> (\actions ->
                    if Ui.isSmall device then
                        Element.el
                            [ Element.htmlAttribute
                                (Html.Attributes.style "padding-bottom"
                                    "calc(14px + env(safe-area-inset-bottom))"
                                )
                            ]
                            actions

                    else
                        actions
               )
        , View.Nutrients.nutritionCard theme device nutrients
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


foodHeader : Theme -> Device -> ProductDetail -> Element Msg
foodHeader theme device food =
    let
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
            , actions = []
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
