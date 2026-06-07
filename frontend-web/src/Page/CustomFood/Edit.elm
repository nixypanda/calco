module Page.CustomFood.Edit exposing
    ( LoadedModel
    , LoadingModel
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , SubmitState(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CategorySuggestionResponse
        , CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , ProductDetail
        , UnitItem
        )
import Api.Result as ApiResult
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
import View.CustomFoodForm as Form


type Model
    = Loading LoadingModel
    | Loaded LoadedModel
    | LoadFailed String


type alias LoadingModel =
    { productId : String
    , food : Maybe ProductDetail
    , nutrients : Maybe (List NutrientItem)
    , units : Maybe (List UnitItem)
    }


type alias LoadedModel =
    { productId : String
    , form : Form.FormModel
    , nutrients : List NutrientItem
    , units : List UnitItem
    , submit : SubmitState
    }


type SubmitState
    = Editing
    | Submitting
    | Failed String


type Msg
    = FoodLoaded (Result Client.ApiError ProductDetail)
    | NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | CategorySuggestionsLoaded Int (Result Client.ApiError CategorySuggestionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)


type OutMsg
    = NoOp
    | RequestInitialData String
    | RequestUpdateFood String CreateFoodRequest
    | RequestCategorySuggestions Int Foods.CategorySuggestionRequest
    | Navigate Route
    | SessionExpired


init : String -> ( Model, OutMsg )
init productId =
    ( Loading
        { productId = productId
        , food = Nothing
        , nutrients = Nothing
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

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    case model of
                        Loaded loaded ->
                            let
                                ( nextForm, subCmd, _ ) =
                                    Form.update (Form.NutrientsLoaded response.items) loaded.form
                            in
                            ( Loaded { loaded | form = nextForm, nutrients = response.items }
                            , Cmd.map FormMsg subCmd
                            , NoOp
                            )

                        _ ->
                            ( setLoadedNutrients response.items model, Cmd.none, NoOp )

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
                    let
                        ( nextForm, subCmd, formOut ) =
                            Form.update subMsg loaded.form
                    in
                    ( Loaded
                        { loaded
                            | form = nextForm
                            , submit = Editing
                        }
                    , Cmd.map FormMsg subCmd
                    , case formOut of
                        Form.NoOutMsg ->
                            NoOp

                        Form.RequestCategorySuggestions token request ->
                            RequestCategorySuggestions token request
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        CategorySuggestionsLoaded token result ->
            case model of
                Loaded loaded ->
                    let
                        ( nextForm, subCmd, _ ) =
                            Form.update
                                (Form.CategorySuggestionsLoaded token
                                    (Result.map .items result)
                                )
                                loaded.form
                    in
                    ( Loaded { loaded | form = nextForm }
                    , Cmd.map FormMsg subCmd
                    , NoOp
                    )

                _ ->
                    ( model, Cmd.none, NoOp )

        SubmitClicked ->
            case model of
                Loaded loaded ->
                    submitLoaded loaded

                _ ->
                    ( model, Cmd.none, NoOp )

        SaveCompleted result ->
            case model of
                Loaded loaded ->
                    if loaded.submit == Submitting then
                        completeSave result model

                    else
                        ( model, Cmd.none, NoOp )

                _ ->
                    ( model, Cmd.none, NoOp )


submitLoaded : LoadedModel -> ( Model, Cmd Msg, OutMsg )
submitLoaded loaded =
    case Form.toCreateFoodRequest loaded.form of
        Ok request ->
            let
                form : Form.FormModel
                form =
                    loaded.form
            in
            ( Loaded
                { loaded
                    | form = { form | submitting = True, error = Nothing }
                    , submit = Submitting
                }
            , Cmd.none
            , RequestUpdateFood loaded.productId request
            )

        Err validationError ->
            let
                form : Form.FormModel
                form =
                    loaded.form
            in
            ( Loaded
                { loaded
                    | form =
                        { form
                            | submitting = False
                            , error = Just (validationMessage validationError)
                        }
                    , submit = Editing
                }
            , Cmd.none
            , NoOp
            )


validationMessage : Form.ValidationError -> String
validationMessage err =
    case err of
        Form.NameRequired ->
            "Name is required"

        Form.InvalidNutrientAmount value ->
            "Nutrient amount must be a non-negative number (got: " ++ value ++ ")"

        Form.InvalidServingQuantity value ->
            "Serving quantity must be a positive number (got: " ++ value ++ ")"

        Form.InvalidServingGrams value ->
            "Serving grams must be a positive number (got: " ++ value ++ ")"


completeSave :
    Result Client.ApiError CreateFoodResponse
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
completeSave result model =
    case result of
        Ok response ->
            ( model, Cmd.none, Navigate (FoodDetail response.id Nothing) )

        Err error ->
            ApiResult.failure
                { noOp = NoOp
                , sessionExpired = SessionExpired
                , applyError =
                    \message current ->
                        applySubmitError message current
                }
                error
                model


setLoadedFood : ProductDetail -> Model -> Model
setLoadedFood food model =
    case model of
        Loading loading ->
            completeLoading { loading | food = Just food }

        Loaded loaded ->
            Loaded
                { loaded
                    | form = Form.fromProductDetail food
                    , submit = Editing
                }

        LoadFailed _ ->
            model


setLoadedNutrients : List NutrientItem -> Model -> Model
setLoadedNutrients nutrients model =
    case model of
        Loading loading ->
            completeLoading { loading | nutrients = Just nutrients }

        Loaded loaded ->
            Loaded { loaded | nutrients = nutrients }

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
    case ( loading.food, loading.nutrients, loading.units ) of
        ( Just food, Just nutrients, Just units ) ->
            Loaded
                { productId = loading.productId
                , form = Form.fromProductDetail food
                , nutrients = nutrients
                , units = units
                , submit = Editing
                }

        _ ->
            Loading loading


applySubmitError : String -> Model -> Model
applySubmitError message model =
    case model of
        Loaded loaded ->
            let
                form : Form.FormModel
                form =
                    loaded.form
            in
            Loaded
                { loaded
                    | form = { form | submitting = False }
                    , submit = Failed message
                }

        _ ->
            model


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message _ -> LoadFailed message
        }


view : { model : Model, device : Device } -> Element Msg
view config =
    Ui.pageContainer config.device
        [ errorView config.model
        , bodyView config
        ]


errorView : Model -> Element Msg
errorView model =
    case model of
        Loaded loaded ->
            case loaded.submit of
                Failed message ->
                    Ui.errorBanner message

                _ ->
                    Element.none

        LoadFailed message ->
            Ui.errorBanner message

        Loading _ ->
            Element.none


bodyView : { model : Model, device : Device } -> Element Msg
bodyView { model, device } =
    case model of
        Loaded loaded ->
            Element.column [ Element.width Element.fill, Element.spacing 14 ]
                [ Element.map FormMsg (Form.view device loaded.nutrients loaded.units loaded.form)
                , Ui.submitButton
                    (loaded.submit == Submitting)
                    "Save Food"
                    "Saving..."
                    SubmitClicked
                ]

        LoadFailed _ ->
            Element.none

        Loading _ ->
            Ui.loading "Loading food..."
