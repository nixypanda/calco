module Page.Meal.Form.Create exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Meals exposing (CreateMealRequest, Meal)
import Api.Result as ApiResult
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Page.Meal.Form.Common as Common
import Ui


type alias Model =
    Common.FormFields


type Msg
    = FormMsg Common.FormFieldMsg
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)


type OutMsg
    = NoOp
    | FormOutMsg Common.FormFieldOutMsg
    | RequestCreateMeal CreateMealRequest
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Common.emptyFormFields, NoOp )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg fields =
    case msg of
        FormMsg formMsg ->
            let
                ( nextFields, cmd, formOutMsg ) =
                    Common.updateFormField formMsg fields
            in
            ( nextFields
            , Cmd.map FormMsg cmd
            , mapFormOutMsg formOutMsg
            )

        SubmitClicked ->
            case Common.toMealRequest fields of
                Ok request ->
                    ( { fields | submitting = True, error = Nothing }
                    , Cmd.none
                    , RequestCreateMeal request
                    )

                Err Common.MealNameRequired ->
                    ( { fields
                        | error = Just "Name is required"
                        , submitting = False
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err Common.ComponentRequired ->
                    ( { fields
                        | error =
                            Just
                                "At least one component with a selected product is required"
                        , submitting = False
                      }
                    , Cmd.none
                    , NoOp
                    )

        SaveCompleted result ->
            case result of
                Ok meal ->
                    ( { fields | submitting = False }
                    , Cmd.none
                    , Navigate (MealDetail meal.id)
                    )

                Err error ->
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current
                                    | submitting = False
                                    , error = Just message
                                }
                        }
                        error
                        fields


mapFormOutMsg : Maybe Common.FormFieldOutMsg -> OutMsg
mapFormOutMsg maybeOutMsg =
    case maybeOutMsg of
        Nothing ->
            NoOp

        Just (Common.RequestProductName productId) ->
            FormOutMsg (Common.RequestProductName productId)

        Just (Common.RequestProductSearch rowId token request) ->
            FormOutMsg (Common.RequestProductSearch rowId token request)

        Just (Common.RequestCategorySuggestions rowId token request) ->
            FormOutMsg (Common.RequestCategorySuggestions rowId token request)

        Just (Common.RequestProductAndCats requests) ->
            FormOutMsg (Common.RequestProductAndCats requests)

        Just Common.FormSessionExpired ->
            SessionExpired


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    let
        fields : Common.FormFields
        fields =
            model
    in
    Ui.pageContainer device
        [ Common.errorView fields
        , Common.viewFormFields FormMsg fields
        , Ui.submitButton fields.submitting
            "Create Meal"
            "Saving..."
            SubmitClicked
        ]
