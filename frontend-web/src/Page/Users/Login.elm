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
import Element exposing (Device, Element)
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Ui.Theme exposing (Theme)



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
    Text.requireTrimmed (I18n.t TidCommonUsernameRequired) form.username
        |> Result.andThen
            (\username ->
                if String.isEmpty form.password then
                    Err (I18n.t TidLoginPasswordRequired)

                else
                    Ok { username = username, password = form.password }
            )


config : CredentialForm.Config Auth.LoginRequest
config =
    { validate = loginPayload
    , title = I18n.t TidLoginTitle
    , description = Nothing
    , submitLabel = I18n.t TidLoginSubmit
    , submittingLabel = I18n.t TidLoginSubmitting
    }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        FormMsg formMsg ->
            let
                ( newModel, formOut ) =
                    CredentialForm.update config formMsg model
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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view props =
    Element.map FormMsg (CredentialForm.view config props)
