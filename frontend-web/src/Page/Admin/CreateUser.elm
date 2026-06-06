module Page.Admin.CreateUser exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , State(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Api.Result as ApiResult
import Data.Auth as Auth
import Data.User as User
import Element exposing (Device, Element)
import Lib.Text as Text
import Ui


type alias Form =
    { username : String
    , displayName : String
    , initialPassword : String
    }


type alias Model =
    { state : State
    }


type State
    = Editing Form
    | Invalid Form Problem
    | Submitting Form
    | Failed Form String
    | Succeeded


type Problem
    = UsernameRequired
    | DisplayNameRequired
    | InitialPasswordRequired


type Msg
    = UsernameChanged String
    | DisplayNameChanged String
    | PasswordChanged String
    | Submitted
    | Completed (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestCreateUser User.CreateUserRequest
    | CreateSucceeded
    | SessionExpired


init : ( Model, OutMsg )
init =
    ( { state = Editing emptyForm }
    , NoOp
    )


emptyForm : Form
emptyForm =
    { username = "", displayName = "", initialPassword = "" }


currentForm : State -> Form
currentForm state =
    case state of
        Editing form ->
            form

        Invalid form _ ->
            form

        Submitting form ->
            form

        Failed form _ ->
            form

        Succeeded ->
            emptyForm


createUserPayload : Form -> Result Problem User.CreateUserRequest
createUserPayload form =
    Result.map2
        (\username displayName ->
            { username = username
            , displayName = displayName
            , initialPassword = form.initialPassword
            }
        )
        (Text.requireTrimmed UsernameRequired form.username)
        (Text.requireTrimmed DisplayNameRequired form.displayName)
        |> Result.andThen
            (\request ->
                if String.isEmpty form.initialPassword then
                    Err InitialPasswordRequired

                else
                    Ok request
            )


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            let
                form : Form
                form =
                    currentForm model.state
            in
            ( { model | state = Editing { form | username = username } }, Cmd.none, NoOp )

        DisplayNameChanged displayName ->
            let
                form : Form
                form =
                    currentForm model.state
            in
            ( { model | state = Editing { form | displayName = displayName } }, Cmd.none, NoOp )

        PasswordChanged password ->
            let
                form : Form
                form =
                    currentForm model.state
            in
            ( { model | state = Editing { form | initialPassword = password } }, Cmd.none, NoOp )

        Submitted ->
            let
                form : Form
                form =
                    currentForm model.state
            in
            case createUserPayload form of
                Ok request ->
                    ( { model | state = Submitting form }
                    , Cmd.none
                    , RequestCreateUser request
                    )

                Err problem ->
                    ( { model | state = Invalid form problem }, Cmd.none, NoOp )

        Completed result ->
            case result of
                Ok _ ->
                    ( { model | state = Succeeded }, Cmd.none, CreateSucceeded )

                Err error ->
                    let
                        form : Form
                        form =
                            currentForm model.state
                    in
                    ApiResult.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message current -> { current | state = Failed form message }
                        }
                        error
                        model


view : { model : Model, device : Device } -> Element Msg
view { model, device } =
    let
        form : Form
        form =
            currentForm model.state
    in
    Ui.pageContainer device
        (errorView model.state
            ++ [ Ui.card
                    [ Ui.input "Username" form.username UsernameChanged
                    , Ui.input "Display Name" form.displayName DisplayNameChanged
                    , Ui.passwordInput "Initial Password" form.initialPassword PasswordChanged
                    , Ui.button "Save" Submitted
                    ]
               ]
        )


errorView : State -> List (Element msg)
errorView state =
    case state of
        Invalid _ problem ->
            [ Ui.errorBanner (problemMessage problem) ]

        Failed _ message ->
            [ Ui.errorBanner message ]

        _ ->
            []


problemMessage : Problem -> String
problemMessage problem =
    case problem of
        UsernameRequired ->
            "Username is required"

        DisplayNameRequired ->
            "Display name is required"

        InitialPasswordRequired ->
            "Initial password is required"
