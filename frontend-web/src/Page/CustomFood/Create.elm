module Page.CustomFood.Create exposing (Model, Msg(..), OutMsg(..), init, update, view)

import Api.Client as Client
import Api.Foods as Foods
    exposing
        ( CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , UnitItem
        )
import Element exposing (Element)
import Page.ApiResult as ApiResult
import Page.CustomFood.Form as Form
import Route exposing (Route(..))
import Ui


type alias Model =
    { form : Form.FormModel
    , nutrients : List NutrientItem
    , units : List UnitItem
    , error : Maybe String
    }


type Msg
    = NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)


type OutMsg
    = NoOp
    | RequestInitialData
    | RequestCreateFood CreateFoodRequest
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { form = Form.emptyForm, nutrients = [], units = [], error = Nothing }
    , RequestInitialData
    )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NutrientsLoaded result ->
            case result of
                Ok response ->
                    ( { model | nutrients = response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = response.items, error = Nothing }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            ( { model | form = Form.update subMsg model.form }, Cmd.none, NoOp )

        SubmitClicked ->
            case Form.toCreateFoodRequest model.form of
                Ok request ->
                    let
                        form : Form.FormModel
                        form =
                            model.form

                        nextForm : Form.FormModel
                        nextForm =
                            setSubmitting True { form | error = Nothing }
                    in
                    ( { model | form = nextForm, error = Nothing }
                    , Cmd.none
                    , RequestCreateFood request
                    )

                Err Form.NameRequired ->
                    let
                        form : Form.FormModel
                        form =
                            model.form
                    in
                    ( { model | form = { form | error = Just "Name is required" } }
                    , Cmd.none
                    , NoOp
                    )

        SaveCompleted result ->
            case result of
                Ok response ->
                    ( model, Cmd.none, Navigate (FoodDetail response.id Nothing) )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current
                                    | form = setSubmitting False current.form
                                    , error = Just message
                                }
                        }
                        error
                        model


setSubmitting : Bool -> Form.FormModel -> Form.FormModel
setSubmitting submitting form =
    { form | submitting = submitting }


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    ApiResult.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | error = Just message }
        }


view : Model -> Element Msg
view model =
    Ui.pageContainer
        [ case model.error of
            Just message ->
                Ui.errorBanner message

            Nothing ->
                Element.none
        , Element.map FormMsg (Form.view model.nutrients model.units model.form)
        , Ui.submitButton model.form.submitting "Create Food" "Creating..." SubmitClicked
        ]
