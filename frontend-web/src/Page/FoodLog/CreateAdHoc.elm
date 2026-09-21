module Page.FoodLog.CreateAdHoc exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , SubmitState(..)
    , init
    , update
    , view
    , viewForAi
    )

import Api.Client as Client
import Api.Foods
    exposing
        ( CategorySuggestionResponse
        , CreateFoodRequest
        , CreateFoodResponse
        , NutrientItem
        , UnitItem
        )
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Component.FoodEditor as Editor
import Data.FoodLog exposing (FoodLog)
import Data.LocalContext exposing (LocalContext)
import Data.MealSlot exposing (MealSlot)
import Element exposing (Element)
import I18n
import Lib.Ticket exposing (Ticket)
import Translations.Ids exposing (TranslationId(..))
import Ui.Button as Button
import Ui.Env exposing (Env)
import Ui.Feedback as Feedback
import Ui.Page as UiPage


type alias Model =
    { form : Editor.FormModel
    , units : List UnitItem
    , nutrients : List NutrientItem
    , deviceTimezone : Maybe String
    , submit : SubmitState
    }


type SubmitState
    = SubmitIdle
    | AwaitingLocalContext
    | LoggingAdHoc
    | SavingCustomFood
    | LoggingSavedFood String
    | SubmitFailed String
    | LogFailedAfterFoodSaved { productId : String, message : String }


init : Maybe String -> Maybe MealSlot -> Model
init date mealSlot =
    { form = Editor.emptyLogForm date mealSlot
    , units = []
    , nutrients = []
    , deviceTimezone = Nothing
    , submit = SubmitIdle
    }


type Msg
    = UnitsLoaded (Result Client.ApiError Api.Foods.UnitListResponse)
    | NutrientsLoaded (Result Client.ApiError Api.Foods.NutrientListResponse)
    | FormMsg Editor.Msg
    | CategorySuggestionsLoaded Ticket (Result Client.ApiError CategorySuggestionResponse)
    | SubmitClicked
    | LocalContextReceived LocalContext
    | AdHocLogCompleted (Result Client.ApiError FoodLog)
    | CustomFoodCompleted (Result Client.ApiError CreateFoodResponse)
    | ProductLogCompleted (Result Client.ApiError FoodLog)


type OutMsg
    = NoOp
    | RequestLocalContext
    | RequestAdHocLog CreateAdHocLogRequest
    | RequestCreateFood CreateFoodRequest
    | RequestCategorySuggestions Ticket Api.Foods.CategorySuggestionRequest
    | RequestProductLog CreateLogRequest
    | LogCreated FoodLog
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UnitsLoaded result ->
            case result of
                Ok response ->
                    ( { model | units = response.items }, Cmd.none, NoOp )

                Err error ->
                    failure error model

        NutrientsLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | nutrients = response.items
                        , form = Editor.withNutrientCatalog response.items model.form
                      }
                    , Cmd.none
                    , NoOp
                    )

                Err error ->
                    failure error model

        FormMsg subMsg ->
            applyFormMsg subMsg model

        CategorySuggestionsLoaded token result ->
            applyFormMsg (Editor.CategorySuggestionsLoaded token (Result.map .items result)) model

        SubmitClicked ->
            submit model

        LocalContextReceived context ->
            if model.submit == AwaitingLocalContext then
                startSubmission
                    { model
                        | form = setDateIfBlank context.date model.form
                        , deviceTimezone = Just context.timezone
                    }

            else
                ( model, Cmd.none, NoOp )

        AdHocLogCompleted result ->
            case result of
                Ok log ->
                    ( { model | submit = SubmitIdle }, Cmd.none, LogCreated log )

                Err error ->
                    failure error model

        CustomFoodCompleted result ->
            case result of
                Ok response ->
                    requestProductLog response.id model

                Err error ->
                    failure error model

        ProductLogCompleted result ->
            case result of
                Ok log ->
                    ( { model | submit = SubmitIdle }, Cmd.none, LogCreated log )

                Err error ->
                    productLogFailure error model


applyFormMsg : Editor.Msg -> Model -> ( Model, Cmd Msg, OutMsg )
applyFormMsg subMsg model =
    let
        ( form, command, formOutMsg ) =
            Editor.update subMsg model.form
    in
    ( { model | form = form, submit = clearFailure model.submit }
    , Cmd.map FormMsg command
    , case formOutMsg of
        Editor.NoOutMsg ->
            NoOp

        Editor.RequestCategorySuggestions token request ->
            RequestCategorySuggestions token request
    )


clearFailure : SubmitState -> SubmitState
clearFailure state =
    case state of
        SubmitFailed _ ->
            SubmitIdle

        LogFailedAfterFoodSaved saved ->
            LogFailedAfterFoodSaved saved

        _ ->
            state


submit : Model -> ( Model, Cmd Msg, OutMsg )
submit model =
    case model.submit of
        LogFailedAfterFoodSaved saved ->
            requestProductLog saved.productId model

        SubmitIdle ->
            submitWithContext model

        SubmitFailed _ ->
            submitWithContext model

        _ ->
            ( model, Cmd.none, NoOp )


submitWithContext : Model -> ( Model, Cmd Msg, OutMsg )
submitWithContext model =
    case model.form.context of
        Editor.FoodLogContext logFields _ ->
            if String.isEmpty (String.trim logFields.date) then
                ( { model | submit = AwaitingLocalContext }, Cmd.none, RequestLocalContext )

            else
                startSubmission model

        Editor.CustomFoodContext ->
            validationFailure (I18n.en TidFoodEditorErrorNotConfigured) model


startSubmission : Model -> ( Model, Cmd Msg, OutMsg )
startSubmission model =
    case model.form.context of
        Editor.FoodLogContext _ Editor.LogAdHocOnly ->
            case Editor.toAdHocLogRequest model.deviceTimezone model.form of
                Ok request ->
                    ( { model | submit = LoggingAdHoc }, Cmd.none, RequestAdHocLog request )

                Err message ->
                    validationFailure message model

        Editor.FoodLogContext _ (Editor.SaveCustomFoodThenLog _) ->
            case Editor.toCustomFoodFromLogRequest model.form of
                Ok request ->
                    ( { model | submit = SavingCustomFood }, Cmd.none, RequestCreateFood request )

                Err message ->
                    validationFailure message model

        Editor.CustomFoodContext ->
            validationFailure (I18n.en TidFoodEditorErrorNotConfigured) model


requestProductLog : String -> Model -> ( Model, Cmd Msg, OutMsg )
requestProductLog productId model =
    case Editor.toProductLogRequest model.deviceTimezone productId model.form of
        Ok request ->
            ( { model | submit = LoggingSavedFood productId }, Cmd.none, RequestProductLog request )

        Err message ->
            validationFailure message model


setDateIfBlank : String -> Editor.FormModel -> Editor.FormModel
setDateIfBlank date form =
    case form.context of
        Editor.FoodLogContext logFields persistence ->
            if String.isEmpty (String.trim logFields.date) then
                { form
                    | context =
                        Editor.FoodLogContext { logFields | date = date } persistence
                }

            else
                form

        Editor.CustomFoodContext ->
            form


productLogFailure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
productLogFailure error model =
    if Client.isUnauthorized error then
        ( model, Cmd.none, SessionExpired )

    else
        case savedProductId model.submit of
            Just productId ->
                ( { model
                    | submit =
                        LogFailedAfterFoodSaved
                            { productId = productId, message = I18n.en TidFoodLogSavedNotLogged }
                  }
                , Cmd.none
                , NoOp
                )

            Nothing ->
                failure error model


savedProductId : SubmitState -> Maybe String
savedProductId state =
    case state of
        LoggingSavedFood productId ->
            Just productId

        LogFailedAfterFoodSaved saved ->
            Just saved.productId

        _ ->
            Nothing


validationFailure : String -> Model -> ( Model, Cmd Msg, OutMsg )
validationFailure message model =
    ( { model | submit = SubmitFailed message }, Cmd.none, NoOp )


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure error model =
    if Client.isUnauthorized error then
        ( model, Cmd.none, SessionExpired )

    else
        validationFailure (Client.displayError error) model


view : Env -> Model -> Element Msg
view env model =
    viewForAi env True model


viewForAi : Env -> Bool -> Model -> Element Msg
viewForAi env showOptional model =
    let
        visibility : Editor.NutrientVisibility
        visibility =
            if showOptional then
                Editor.AllNutrients

            else
                Editor.CoreNutrientsOnly
    in
    UiPage.pageContainer
        [ Feedback.maybeErrorBanner env.theme (submitError model.submit)
        , Element.map FormMsg
            (Editor.viewForLog env visibility model.nutrients model.units model.form)
        , Button.textButton env.device
            env.theme
            { tone = Button.Primary
            , width = Button.FullWidth
            , label =
                case model.submit of
                    LogFailedAfterFoodSaved _ ->
                        I18n.t env.language TidFoodLogRetryLogging

                    _ ->
                        I18n.t env.language TidTitleLogFood
            , onPress = SubmitClicked
            , submitState = Just (Button.submittingOrIdle (isSubmitting model.submit))
            , submittingLabel = Just (I18n.t env.language TidFoodShowLogging)
            , trailing = Nothing
            }
        ]


submitError : SubmitState -> Maybe String
submitError state =
    case state of
        SubmitFailed message ->
            Just message

        LogFailedAfterFoodSaved saved ->
            Just saved.message

        _ ->
            Nothing


isSubmitting : SubmitState -> Bool
isSubmitting state =
    case state of
        AwaitingLocalContext ->
            True

        LoggingAdHoc ->
            True

        SavingCustomFood ->
            True

        LoggingSavedFood _ ->
            True

        _ ->
            False
