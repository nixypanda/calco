module Page.CustomFood.Create exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , initWithAssistant
    , modalView
    , photoPreviewUrls
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
        , UnitItem
        )
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Form
import Data.FoodAssistant exposing (Conversation, FoodDraftPurpose)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
import File exposing (File)
import I18n
import Lib.Ticket exposing (Ticket)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Feedback as Feedback
import Ui.Page as UiPage
import Ui.Theme exposing (Theme)



-- MODEL


type alias Model =
    { form : Form.FormModel
    , assistant : Assistant.Model
    , assistantOnly : Bool
    , nutrients : List NutrientItem
    , units : List UnitItem
    , error : Maybe String
    }


init : ( Model, OutMsg )
init =
    ( { form = Form.emptyForm
      , assistant = Tuple.first Assistant.init
      , assistantOnly = False
      , nutrients = []
      , units = []
      , error = Nothing
      }
    , NoOp
    )


initWithAssistant : ( Model, OutMsg )
initWithAssistant =
    ( { form = Form.emptyForm
      , assistant = Tuple.first Assistant.init
      , assistantOnly = True
      , nutrients = []
      , units = []
      , error = Nothing
      }
    , RequestInitialData
    )


photoPreviewUrls : Model -> List String
photoPreviewUrls model =
    Assistant.previewUrls model.assistant



-- UPDATE


type Msg
    = NutrientsLoaded (Result Client.ApiError Foods.NutrientListResponse)
    | UnitsLoaded (Result Client.ApiError Foods.UnitListResponse)
    | FormMsg Form.Msg
    | AssistantMsg Assistant.Msg
    | CategorySuggestionsLoaded Ticket (Result Client.ApiError CategorySuggestionResponse)
    | SubmitClicked
    | SaveCompleted (Result Client.ApiError CreateFoodResponse)


type OutMsg
    = NoOp
    | RequestInitialData
    | RequestCreateFood CreateFoodRequest
    | RequestCategorySuggestions Ticket Foods.CategorySuggestionRequest
    | RequestAssistantStatus
    | RequestFoodDraft FoodDraftPurpose Conversation (List File)
    | RevokePhotoPreviewUrls (List String)
    | Navigate Route
    | SessionExpired


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        NutrientsLoaded result ->
            case result of
                Ok response ->
                    ( { model
                        | nutrients = response.items
                        , form = Form.withNutrientCatalog response.items model.form
                        , error = Nothing
                      }
                    , Cmd.none
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

        AssistantMsg subMsg ->
            let
                ( nextAssistant, subCmd, assistantOut ) =
                    Assistant.update subMsg model.assistant
            in
            applyAssistantOutMsg assistantOut
                { model | assistant = nextAssistant }
                (Cmd.map AssistantMsg subCmd)

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
            case Form.toInitialCreateFoodRequest model.form of
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
                    ( model, Cmd.none, Navigate (CustomFoodShow response.id) )

                Err error ->
                    Client.failure
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
            I18n.en TidCustomFoodNameRequired

        Form.InvalidNutrientAmount value ->
            I18n.en (TidCustomFoodInvalidNutrientAmount value)

        Form.InvalidServingGrams value ->
            I18n.en (TidCustomFoodInvalidServingGrams value)

        Form.DuplicateServingUnit unit ->
            I18n.en (TidCustomFoodDuplicateServingUnit unit)

        Form.InvalidDefaultPortion ->
            I18n.en TidCustomFoodInvalidDefaultPortion


withSubmit : Form.SubmitState -> Form.FormModel -> Form.FormModel
withSubmit state form =
    { form | submit = state }


failure : Client.ApiError -> Model -> ( Model, Cmd Msg, OutMsg )
failure =
    Client.failure
        { noOp = NoOp
        , sessionExpired = SessionExpired
        , applyError = \message model -> { model | error = Just message }
        }


applyAssistantOutMsg :
    Assistant.OutMsg
    -> Model
    -> Cmd Msg
    -> ( Model, Cmd Msg, OutMsg )
applyAssistantOutMsg assistantOut model command =
    case assistantOut of
        Assistant.NoOutMsg ->
            ( model, command, NoOp )

        Assistant.RequestStatus ->
            ( model, command, RequestAssistantStatus )

        Assistant.RequestDraft purpose conversation photos ->
            ( model, command, RequestFoodDraft purpose conversation photos )

        Assistant.RevokePhotoPreviewUrls urls ->
            ( model, command, RevokePhotoPreviewUrls urls )

        Assistant.ApplyDraft draft ->
            ( { model
                | form = Form.applyAiDraft draft model.form
                , assistantOnly = False
              }
            , command
            , NoOp
            )

        Assistant.CompleteDraft _ ->
            ( model, command, NoOp )

        Assistant.SessionExpired ->
            ( model, command, SessionExpired )



-- VIEW


view :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Element Msg
view { model, device, theme, language } =
    let
        content : List (Element Msg)
        content =
            if model.assistantOnly then
                [ Element.map AssistantMsg
                    (Assistant.view theme language device False model.assistant)
                ]

            else
                [ Element.map FormMsg
                    (Form.viewForCreate theme language device model.nutrients model.form)
                , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t language TidTitleCreateFood
                    , onPress = SubmitClicked
                    , submitState =
                        Just
                            (Button.submittingOrIdle
                                (Form.isSubmitting model.form.submit)
                            )
                    , submittingLabel = Just (I18n.t language TidCommonCreating)
                    , trailing = Nothing
                    }
                ]
    in
    UiPage.pageContainer (Feedback.maybeErrorBanner theme model.error :: content)


modalView :
    { model : Model, device : Device, theme : Theme, language : Language }
    -> Maybe (Element Msg)
modalView { model, device, theme, language } =
    Assistant.modalView theme language device model.assistant
        |> Maybe.map (Element.map AssistantMsg)
