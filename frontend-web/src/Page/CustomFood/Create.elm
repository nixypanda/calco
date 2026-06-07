module Page.CustomFood.Create exposing (Model, Msg(..), OutMsg(..), init, update, view)

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CategorySuggestionResponse
        , CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , UnitItem
        )
import Api.Result as ApiResult
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui
import Page.CustomFood.Form as Form



-- MODEL


type alias Model =
    { form : Form.FormModel
    , nutrients : List NutrientItem
    , units : List UnitItem
    , error : Maybe String
    }


init : ( Model, OutMsg )
init =
    ( { form = Form.emptyForm, nutrients = [], units = [], error = Nothing }
    , RequestInitialData
    )



-- UPDATE


type Msg
    = NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | CategorySuggestionsLoaded Int (Result Client.ApiError CategorySuggestionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)


type OutMsg
    = NoOp
    | RequestInitialData
    | RequestCreateFood CreateFoodRequest
    | RequestCategorySuggestions Int Foods.CategorySuggestionRequest
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NutrientsLoaded result ->
            case result of
                Ok response ->
                    let
                        ( nextForm, subCmd, _ ) =
                            Form.update (Form.NutrientsLoaded response.items) model.form
                    in
                    ( { model
                        | nutrients = response.items
                        , form = nextForm
                        , error = Nothing
                      }
                    , Cmd.map FormMsg subCmd
                    , NoOp
                    )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            let
                ( nextForm, subCmd, formOut ) =
                    Form.update subMsg model.form
            in
            ( { model | form = nextForm }
            , Cmd.map FormMsg subCmd
            , case formOut of
                Form.NoOutMsg ->
                    NoOp

                Form.RequestCategorySuggestions token request ->
                    RequestCategorySuggestions token request
            )

        CategorySuggestionsLoaded token result ->
            let
                ( nextForm, subCmd, _ ) =
                    Form.update
                        (Form.CategorySuggestionsLoaded token
                            (Result.map .items result)
                        )
                        model.form
            in
            ( { model | form = nextForm }
            , Cmd.map FormMsg subCmd
            , NoOp
            )

        SubmitClicked ->
            case Form.toCreateFoodRequest model.form of
                Ok request ->
                    ( { model | form = withSubmit Form.Submitting model.form, error = Nothing }
                    , Cmd.none
                    , RequestCreateFood request
                    )

                Err validationError ->
                    ( { model
                        | form =
                            withSubmit
                                (Form.SubmitFailed (validationMessage validationError))
                                model.form
                      }
                    , Cmd.none
                    , NoOp
                    )

        SaveCompleted result ->
            case result of
                Ok response ->
                    ( model, Cmd.none, Navigate (FoodShow response.id Nothing) )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current
                                    | form =
                                        withSubmit
                                            (Form.SubmitFailed message)
                                            current.form
                                }
                        }
                        error
                        model


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


withSubmit : Form.SubmitState -> Form.FormModel -> Form.FormModel
withSubmit state form =
    { form | submit = state }


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | error = Just message }
        }



-- VIEW


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    Ui.pageContainer device
        [ Ui.maybeErrorBanner model.error
        , Element.map FormMsg (Form.view device model.nutrients model.units model.form)
        , Ui.submitButton (Form.isSubmitting model.form.submit)
            "Create Food"
            "Creating..."
            SubmitClicked
        ]
