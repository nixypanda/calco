module Page.Auth.Login exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , State(..)
    , init
    , loginPayload
    , update
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Element exposing (Device, Element)
import Lib.Text as Text
import View.Auth



-- MODEL


type alias Form =
    { username : String
    , password : String
    }


type alias Model =
    { state : State
    , form : Form
    }


init : Model
init =
    { state = Editing, form = emptyForm }


emptyForm : Form
emptyForm =
    { username = "", password = "" }


type State
    = Editing
    | Invalid Problem
    | Submitting
    | Failed String


type Problem
    = UsernameRequired
    | PasswordRequired



-- UPDATE


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Submitted
    | LoginCompleted (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestLogin Auth.LoginRequest
    | LoginSucceeded Auth.LoginSession


loginPayload : Form -> Result Problem Auth.LoginRequest
loginPayload form =
    Text.requireTrimmed UsernameRequired form.username
        |> Result.andThen
            (\username ->
                if String.isEmpty form.password then
                    Err PasswordRequired

                else
                    Ok { username = username, password = form.password }
            )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    let
        form =
            model.form
    in
    case msg of
        UsernameChanged username ->
            ( { state = Editing, form = { form | username = username } }, Cmd.none, NoOp )

        PasswordChanged password ->
            ( { state = Editing, form = { form | password = password } }, Cmd.none, NoOp )

        Submitted ->
            case loginPayload model.form of
                Ok request ->
                    ( { model | state = Submitting }, Cmd.none, RequestLogin request )

                Err problem ->
                    ( { model | state = Invalid problem }, Cmd.none, NoOp )

        LoginCompleted result ->
            case model.state of
                Submitting ->
                    case result of
                        Ok loginSession ->
                            ( model, Cmd.none, LoginSucceeded loginSession )

                        Err error ->
                            ( { model | state = Failed (Client.displayError error) }
                            , Cmd.none
                            , NoOp
                            )

                _ ->
                    ( model, Cmd.none, NoOp )



-- VIEW


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    View.Auth.credentialCard
        { device = device
        , title = "Log In"
        , description = Nothing
        , username = model.form.username
        , password = model.form.password
        , onUsernameChanged = UsernameChanged
        , onPasswordChanged = PasswordChanged
        , error = errorMessage model.state
        , submitting = model.state == Submitting
        , submitLabel = "Log In"
        , submittingLabel = "Logging in..."
        , onSubmit = Submitted
        }


errorMessage : State -> Maybe String
errorMessage state =
    case state of
        Invalid problem ->
            Just (problemMessage problem)

        Failed message ->
            Just message

        _ ->
            Nothing


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        UsernameRequired ->
            "Username is required"

        PasswordRequired ->
            "Password is required"
