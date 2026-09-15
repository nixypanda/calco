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
import Lib.Text as Text
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
    Text.requireTrimmed "Username is required" form.username
        |> Result.andThen
            (\username ->
                if String.length form.password < 8 then
                    Err "Password must be at least 8 characters"

                else
                    Ok { username = username, password = form.password }
            )


config : CredentialForm.Config Auth.LoginRequest
config =
    { validate = validateBootstrapAdmin
    , title = "First-Time Setup"
    , description = Just "Create the admin account to get started."
    , submitLabel = "Create Admin"
    , submittingLabel = "Creating..."
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
                    ( newModel, Cmd.none, RequestCreateAdmin request )

        CreateAdminCompleted (Ok loginSession) ->
            ( model, Cmd.none, CreateAdminSucceeded loginSession )

        CreateAdminCompleted (Err error) ->
            ( CredentialForm.markFailed (Client.displayError error) model
            , Cmd.none
            , NoOp
            )



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view props =
    Element.map FormMsg (CredentialForm.view config props)
