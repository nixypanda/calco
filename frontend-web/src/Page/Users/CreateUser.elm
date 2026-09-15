module Page.Users.CreateUser exposing
    ( Form
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Data.User as User
import Element exposing (Device, Element)
import Lib.Text as Text
import Ui
import Ui.Button as Button
import Ui.Input as UiInput
import Ui.Theme exposing (Theme)



-- MODEL


type alias Form =
    { username : String
    , displayName : String
    , initialPassword : String
    }


type Model
    = Editing Form
    | Invalid Form Problem
    | Submitting Form
    | Failed Form String
    | Succeeded


type Problem
    = UsernameRequired
    | DisplayNameRequired
    | InitialPasswordRequired


init : Model
init =
    Editing emptyForm


emptyForm : Form
emptyForm =
    { username = "", displayName = "", initialPassword = "" }



-- UPDATE


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


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            let
                form : Form
                form =
                    currentForm model
            in
            ( Editing { form | username = username }, Cmd.none, NoOp )

        DisplayNameChanged displayName ->
            let
                form : Form
                form =
                    currentForm model
            in
            ( Editing { form | displayName = displayName }, Cmd.none, NoOp )

        PasswordChanged password ->
            let
                form : Form
                form =
                    currentForm model
            in
            ( Editing { form | initialPassword = password }, Cmd.none, NoOp )

        Submitted ->
            let
                form : Form
                form =
                    currentForm model
            in
            case createUserPayload form of
                Ok request ->
                    ( Submitting form
                    , Cmd.none
                    , RequestCreateUser request
                    )

                Err problem ->
                    ( Invalid form problem, Cmd.none, NoOp )

        Completed result ->
            case result of
                Ok _ ->
                    ( Succeeded, Cmd.none, CreateSucceeded )

                Err error ->
                    let
                        form : Form
                        form =
                            currentForm model
                    in
                    Client.failure
                        { noOp = NoOp
                        , sessionExpired = SessionExpired
                        , applyError = \message _ -> Failed form message
                        }
                        error
                        model


currentForm : Model -> Form
currentForm model =
    case model of
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



-- VIEW


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view { model, device, theme } =
    let
        form : Form
        form =
            currentForm model
    in
    Ui.pageContainer device
        (errorView theme model
            ++ [ Ui.card theme
                    [ UiInput.input theme
                        { label = "Username"
                        , value = form.username
                        , onChange = UsernameChanged
                        }
                    , UiInput.input theme
                        { label = "Display Name"
                        , value = form.displayName
                        , onChange = DisplayNameChanged
                        }
                    , UiInput.passwordInput theme
                        { label = "Initial Password"
                        , value = form.initialPassword
                        , onChange = PasswordChanged
                        }
                    ]
               , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = "Save"
                    , onPress = Submitted
                    , submitState = Just (Button.submittingOrIdle (isSubmitting model))
                    , submittingLabel = Just "Saving..."
                    , trailing = Nothing
                    }
               ]
        )


isSubmitting : Model -> Bool
isSubmitting model =
    case model of
        Submitting _ ->
            True

        _ ->
            False


errorView : Theme -> Model -> List (Element msg)
errorView theme model =
    case model of
        Invalid _ problem ->
            [ Ui.errorBanner theme (problemMessage problem) ]

        Failed _ message ->
            [ Ui.errorBanner theme message ]

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
