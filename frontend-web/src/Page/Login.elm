module Page.Login exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , validateLogin
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Element exposing (Element)
import Element.Font as Font
import Ui


type alias Form =
    { username : String
    , password : String
    }


type alias Model =
    { form : Form
    , submitting : Bool
    , error : Maybe String
    }


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Submitted
    | LoginCompleted (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestLogin Auth.LoginRequest
    | LoginSucceeded Auth.LoginSession


init : Model
init =
    { form = { username = "", password = "" }
    , submitting = False
    , error = Nothing
    }


validateLogin : Form -> Result String Auth.LoginRequest
validateLogin form =
    let
        username : String
        username =
            String.trim form.username
    in
    if String.isEmpty username || String.isEmpty form.password then
        Err "Username and password are required"

    else
        Ok { username = username, password = form.password }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            ( { model | form = updateUsername username model.form }, Cmd.none, NoOp )

        PasswordChanged password ->
            ( { model | form = updatePassword password model.form }, Cmd.none, NoOp )

        Submitted ->
            case validateLogin model.form of
                Ok request ->
                    ( { model | submitting = True, error = Nothing }
                    , Cmd.none
                    , RequestLogin request
                    )

                Err message ->
                    ( { model | error = Just message }, Cmd.none, NoOp )

        LoginCompleted result ->
            case result of
                Ok loginSession ->
                    ( { model | submitting = False, error = Nothing }
                    , Cmd.none
                    , LoginSucceeded loginSession
                    )

                Err error ->
                    ( { model
                        | submitting = False
                        , error = Just (Client.displayError error)
                      }
                    , Cmd.none
                    , NoOp
                    )


updateUsername : String -> Form -> Form
updateUsername username form =
    { form | username = username }


updatePassword : String -> Form -> Form
updatePassword password form =
    { form | password = password }


view : Model -> Element Msg
view model =
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 420)
        , Element.padding 20
        ]
        (Ui.card
            ([ Element.el [ Ui.display, Font.bold ] (Element.text "CalCo")
             , Element.el
                [ Ui.heading2
                , Font.medium
                , Font.color Ui.mediumColor
                ]
                (Element.text "Log In")
             , Ui.input "Username" model.form.username UsernameChanged
             , Ui.passwordInput "Password" model.form.password PasswordChanged
             ]
                ++ errorView model.error
                ++ [ Ui.submitButton model.submitting "Log In" "Logging in..." Submitted ]
            )
        )


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
