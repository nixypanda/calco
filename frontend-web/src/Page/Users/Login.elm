module Page.Users.Login exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , init
    , loginPayload
    , update
    , view
    )

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Element exposing (Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Env exposing (Env)



-- MODEL


type alias Model =
    CredentialForm.Model


type OutMsg
    = NoOp
    | RequestLogin Auth.LoginRequest
    | LoginSucceeded Auth.LoginSession


init : Model
init =
    CredentialForm.init



-- UPDATE


type Msg
    = FormMsg CredentialForm.Msg
    | LoginCompleted (Result Client.ApiError Auth.LoginSession)


loginPayload : CredentialForm.Form -> Result String Auth.LoginRequest
loginPayload form =
    Text.requireTrimmed (I18n.en TidCommonUsernameRequired) form.username
        |> Result.andThen
            (\username ->
                if String.isEmpty form.password then
                    Err (I18n.en TidLoginPasswordRequired)

                else
                    Ok { username = username, password = form.password }
            )


config : Language -> CredentialForm.Config Auth.LoginRequest
config language =
    { validate = loginPayload
    , title = I18n.t language TidLoginTitle
    , description = Nothing
    , submitLabel = I18n.t language TidLoginSubmit
    , submittingLabel = I18n.t language TidLoginSubmitting
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
                    ( newModel, Cmd.none, RequestLogin request )

        LoginCompleted (Ok loginSession) ->
            ( model, Cmd.none, LoginSucceeded loginSession )

        LoginCompleted (Err error) ->
            ( CredentialForm.markFailed (Client.displayError error) model
            , Cmd.none
            , NoOp
            )



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    Element.map FormMsg (CredentialForm.view env (config env.language) model)
