module Page.Admin.BootstrapSetup exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , State(..)
    , bootstrapAdminPayload
    , currentForm
    , init
    , update
    , validateBootstrapAdmin
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Element exposing (Element)
import Lib.Text as Text
import View.Auth


type alias Form =
    { username : String
    , password : String
    }


type alias Model =
    { state : State
    }


type State
    = Editing Form
    | Invalid Form Problem
    | Submitting Form
    | Failed Form String


type Problem
    = UsernameRequired
    | PasswordTooShort


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Submitted
    | CreateAdminCompleted (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestCreateAdmin Auth.LoginRequest
    | CreateAdminSucceeded Auth.LoginSession


init : Model
init =
    { state = Editing emptyForm }


emptyForm : Form
emptyForm =
    { username = "", password = "" }


currentForm : Model -> Form
currentForm model =
    case model.state of
        Editing form ->
            form

        Invalid form _ ->
            form

        Submitting form ->
            form

        Failed form _ ->
            form


bootstrapAdminPayload : Form -> Result Problem Auth.LoginRequest
bootstrapAdminPayload form =
    Text.requireTrimmed UsernameRequired form.username
        |> Result.andThen
            (\username ->
                if String.length form.password < 8 then
                    Err PasswordTooShort

                else
                    Ok { username = username, password = form.password }
            )


validateBootstrapAdmin : Form -> Result Problem Auth.LoginRequest
validateBootstrapAdmin =
    bootstrapAdminPayload


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            let
                form : Form
                form =
                    currentForm model
            in
            ( { model | state = Editing { form | username = username } }, Cmd.none, NoOp )

        PasswordChanged password ->
            let
                form : Form
                form =
                    currentForm model
            in
            ( { model | state = Editing { form | password = password } }, Cmd.none, NoOp )

        Submitted ->
            let
                form : Form
                form =
                    currentForm model
            in
            case bootstrapAdminPayload form of
                Ok request ->
                    ( { model | state = Submitting form }
                    , Cmd.none
                    , RequestCreateAdmin request
                    )

                Err problem ->
                    ( { model | state = Invalid form problem }, Cmd.none, NoOp )

        CreateAdminCompleted result ->
            case model.state of
                Submitting form ->
                    case result of
                        Ok loginSession ->
                            ( model, Cmd.none, CreateAdminSucceeded loginSession )

                        Err error ->
                            ( { model | state = Failed form (Client.displayError error) }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )


view : Model -> Element Msg
view model =
    let
        form : Form
        form =
            currentForm model
    in
    View.Auth.credentialCard
        { title = "First-Time Setup"
        , description = Just "Create the admin account to get started."
        , username = form.username
        , password = form.password
        , onUsernameChanged = UsernameChanged
        , onPasswordChanged = PasswordChanged
        , error = errorMessage model.state
        , submitting = isSubmitting model.state
        , submitLabel = "Create Admin"
        , submittingLabel = "Creating..."
        , onSubmit = Submitted
        }


isSubmitting : State -> Bool
isSubmitting state =
    case state of
        Submitting _ ->
            True

        _ ->
            False


errorMessage : State -> Maybe String
errorMessage state =
    case state of
        Invalid _ problem ->
            Just (problemMessage problem)

        Failed _ message ->
            Just message

        _ ->
            Nothing


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        UsernameRequired ->
            "Username is required"

        PasswordTooShort ->
            "Password must be at least 8 characters"
