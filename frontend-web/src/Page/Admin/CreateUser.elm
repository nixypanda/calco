module Page.Admin.CreateUser exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Data.User as User
import Element exposing (Element)
import Ui


type alias Form =
    { username : String
    , displayName : String
    , initialPassword : String
    }


type alias Model =
    { form : Form
    , actionError : Maybe String
    }


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
    ( { form = { username = "", displayName = "", initialPassword = "" }
      , actionError = Nothing
      }
    , NoOp
    )


createUserPayload : Model -> Result String User.CreateUserRequest
createUserPayload model =
    let
        username : String
        username =
            String.trim model.form.username

        displayName : String
        displayName =
            String.trim model.form.displayName
    in
    if String.isEmpty username then
        Err "Username is required"

    else if String.isEmpty displayName then
        Err "Display name is required"

    else if String.isEmpty model.form.initialPassword then
        Err "Initial password is required"

    else
        Ok
            { username = username
            , displayName = displayName
            , initialPassword = model.form.initialPassword
            }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            ( { model
                | form =
                    { username = username
                    , displayName = model.form.displayName
                    , initialPassword = model.form.initialPassword
                    }
              }
            , Cmd.none
            , NoOp
            )

        DisplayNameChanged displayName ->
            ( { model
                | form =
                    { username = model.form.username
                    , displayName = displayName
                    , initialPassword = model.form.initialPassword
                    }
              }
            , Cmd.none
            , NoOp
            )

        PasswordChanged password ->
            ( { model
                | form =
                    { username = model.form.username
                    , displayName = model.form.displayName
                    , initialPassword = password
                    }
              }
            , Cmd.none
            , NoOp
            )

        Submitted ->
            case createUserPayload model of
                Ok request ->
                    ( { model | actionError = Nothing }, Cmd.none, RequestCreateUser request )

                Err message ->
                    ( { model | actionError = Just message }, Cmd.none, NoOp )

        Completed result ->
            case result of
                Ok _ ->
                    ( model, Cmd.none, CreateSucceeded )

                Err error ->
                    if Client.isUnauthorized error then
                        ( { model | actionError = Just (Client.displayError error) }
                        , Cmd.none
                        , SessionExpired
                        )

                    else
                        ( { model | actionError = Just (Client.displayError error) }
                        , Cmd.none
                        , NoOp
                        )


view : Model -> Element Msg
view model =
    Ui.pageContainer
        (errorView model.actionError
            ++ [ Ui.card
                    [ Ui.input "Username" model.form.username UsernameChanged
                    , Ui.input "Display Name" model.form.displayName DisplayNameChanged
                    , Ui.passwordInput "Initial Password" model.form.initialPassword PasswordChanged
                    , Ui.button "Save" Submitted
                    ]
               ]
        )


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
