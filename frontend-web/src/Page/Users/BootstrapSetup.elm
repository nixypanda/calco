module Page.Users.BootstrapSetup exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , validateBootstrapAdmin
    , view
    )

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Element exposing (Device, Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Theme exposing (Theme)



-- MODEL


type alias Model =
    CredentialForm.Model


type OutMsg
    = NoOp
    | RequestCreateAdmin Auth.LoginRequest
    | CreateAdminSucceeded Auth.LoginSession


init : Model
init =
    CredentialForm.init



-- UPDATE


type Msg
    = FormMsg CredentialForm.Msg
    | CreateAdminCompleted (Result Client.ApiError Auth.LoginSession)


validateBootstrapAdmin : CredentialForm.Form -> Result String Auth.LoginRequest
validateBootstrapAdmin form =
    Text.requireTrimmed (I18n.en TidCommonUsernameRequired) form.username
        |> Result.andThen
            (\username ->
                if String.length form.password < 8 then
                    Err (I18n.en TidSetupPasswordMinLength)

                else
                    Ok { username = username, password = form.password }
            )


config : Language -> CredentialForm.Config Auth.LoginRequest
config language =
    { validate = validateBootstrapAdmin
    , title = I18n.t language TidSetupTitle
    , description = Just (I18n.t language TidSetupDescription)
    , submitLabel = I18n.t language TidSetupSubmit
    , submittingLabel = I18n.t language TidSetupSubmitting
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FormMsg formMsg ->
            let
                ( newModel, formOut ) =
                    CredentialForm.update (config I18n.defaultLanguage) formMsg model
            in
            case formOut of
                CredentialForm.NoOp ->
                    ( newModel, Cmd.none, NoOp )

                CredentialForm.RequestSubmit request ->
                    ( newModel, Cmd.none, RequestCreateAdmin request )

        CreateAdminCompleted (Ok loginSession) ->
            ( model, Cmd.none, CreateAdminSucceeded loginSession )

        CreateAdminCompleted (Err error) ->
            ( CredentialForm.markFailed (Client.displayError error) model
            , Cmd.none
            , NoOp
            )



-- VIEW


view : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
view props =
    Element.map FormMsg (CredentialForm.view (config props.language) props)
