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
import Data.Auth as Auth
import Element exposing (Device, Element)
import Lib.Text as Text
import Page.Users.CredentialForm as CredentialForm
import Ui.Theme exposing (Theme)


type alias Model =
    CredentialForm.Model


type Msg
    = FormMsg CredentialForm.Msg
    | LoginCompleted (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestLogin Auth.LoginRequest
    | LoginSucceeded Auth.LoginSession


init : Model
init =
    CredentialForm.init


loginPayload : CredentialForm.Form -> Result String Auth.LoginRequest
loginPayload form =
    Text.requireTrimmed "Username is required" form.username
        |> Result.andThen
            (\username ->
                if String.isEmpty form.password then
                    Err "Password is required"

                else
                    Ok { username = username, password = form.password }
            )


config : CredentialForm.Config Auth.LoginRequest
config =
    { validate = loginPayload
    , title = "Log In"
    , description = Nothing
    , submitLabel = "Log In"
    , submittingLabel = "Logging in..."
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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view props =
    Element.map FormMsg (CredentialForm.view config props)
