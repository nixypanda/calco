module Page.Meal.Create exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Foods as Foods
import Api.Meals exposing (CreateMealRequest, Meal)
import Component.Meal.Form as Common
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import Ui.Button as Button
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Theme exposing (Theme)



-- MODEL


type alias Model =
    Common.FormFields


type OutMsg
    = NoOp
    | FormOutMsg Common.FormFieldOutMsg
    | RequestCreateMeal CreateMealRequest
    | Navigate Route
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( Common.emptyFormFields, NoOp )



-- UPDATE


type Msg
    = FormMsg Common.FormFieldMsg
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError Meal)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)


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
                    ( { fields | submit = Common.Submitting }
                    , Cmd.none
                    , RequestCreateMeal request
                    )

                Err Common.MealNameRequired ->
                    ( { fields | submit = Common.SubmitFailed "Name is required" }
                    , Cmd.none
                    , NoOp
                    )

                Err Common.ComponentRequired ->
                    ( { fields
                        | submit =
                            Common.SubmitFailed
                                "At least one component with a selected product is required"
                      }
                    , Cmd.none
                    , NoOp
                    )

        SaveCompleted result ->
            case result of
                Ok meal ->
                    ( { fields | submit = Common.Idle }
                    , Cmd.none
                    , Navigate (MealShow meal.id)
                    )

                Err error ->
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError =
                            \message current ->
                                { current | submit = Common.SubmitFailed message }
                        }
                        error
                        fields

        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { fields | units = response.items }, Cmd.none, NoOp )

                Err _ ->
                    ( fields, Cmd.none, NoOp )


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



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    UiPage.pageContainer device
        [ Feedback.maybeErrorBanner theme (Common.submitErrorMessage model.submit)
        , Common.viewFormFields theme device FormMsg model
        , Button.textButton device
            theme
            { tone = Button.Primary
            , width = Button.FullWidth
            , label = "Create Meal"
            , onPress = SubmitClicked
            , submitState = Just (Button.submittingOrIdle (Common.isSubmitting model.submit))
            , submittingLabel = Just "Saving..."
            , trailing = Nothing
            }
        ]
