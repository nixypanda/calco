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
import Element exposing (Element)
import I18n
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage



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
                    ( { fields | submit = Common.SubmitFailed (I18n.en TidCustomFoodNameRequired) }
                    , Cmd.none
                    , NoOp
                    )

                Err Common.ComponentRequired ->
                    ( { fields
                        | submit =
                            Common.SubmitFailed
                                (I18n.en TidMealComponentRequired)
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


view : Env -> Model -> Element Msg
view env model =
    UiPage.pageContainer
        [ Feedback.maybeErrorBanner env.theme (Common.submitErrorMessage model.submit)
        , Common.viewFormFields env FormMsg model
        , Button.textButton env.device
            env.theme
            { tone = Button.Primary
            , width = Button.FullWidth
            , label = I18n.t env.language TidTitleCreateMeal
            , onPress = SubmitClicked
            , submitState = Just (Button.submittingOrIdle (Common.isSubmitting model.submit))
            , submittingLabel = Just (I18n.t env.language TidCommonSaving)
            , trailing = Nothing
            }
        ]
