module Page.BootstrapAdminSetup exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , init
    , update
    , validateBootstrapAdmin
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
    | CreateAdminCompleted (Result Client.ApiError Auth.LoginSession)


type OutMsg
    = NoOp
    | RequestCreateAdmin Auth.LoginRequest
    | CreateAdminSucceeded Auth.LoginSession


init : Model
init =
    { form = { username = "", password = "" }
    , submitting = False
    , error = Nothing
    }


validateBootstrapAdmin : Form -> Result String Auth.LoginRequest
validateBootstrapAdmin form =
    let
        username : String
        username =
            String.trim form.username
    in
    if String.isEmpty username then
        Err "Username is required"

    else if String.length form.password < 8 then
        Err "Password must be at least 8 characters"

    else
        Ok { username = username, password = form.password }


update : Msg -> Model -> ( Model, Cmd Msg, OutMsg )
update msg model =
    case msg of
        UsernameChanged username ->
            ( { model
                | form =
                    { username = username
                    , password = model.form.password
                    }
              }
            , Cmd.none
            , NoOp
            )

        PasswordChanged password ->
            ( { model
                | form =
                    { username = model.form.username
                    , password = password
                    }
              }
            , Cmd.none
            , NoOp
            )

        Submitted ->
            case validateBootstrapAdmin model.form of
                Ok request ->
                    ( { model | submitting = True, error = Nothing }
                    , Cmd.none
                    , RequestCreateAdmin request
                    )

                Err message ->
                    ( { model | error = Just message }, Cmd.none, NoOp )

        CreateAdminCompleted result ->
            case result of
                Ok loginSession ->
                    ( { model | submitting = False, error = Nothing }
                    , Cmd.none
                    , CreateAdminSucceeded loginSession
                    )

                Err error ->
                    ( { model
                        | submitting = False
                        , error = Just (Client.displayError error)
                      }
                    , Cmd.none
                    , NoOp
                    )


view : Model -> Element Msg
view model =
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 420)
        , Element.padding 20
        ]
        (Ui.card
            ([ Element.el [ Font.size 32, Font.bold ] (Element.text "CalCo")
             , Element.el
                [ Font.size 20
                , Font.medium
                , Font.color Ui.mediumColor
                ]
                (Element.text "First-Time Setup")
             , Element.paragraph
                [ Font.size 14
                , Font.color Ui.mediumColor
                ]
                [ Element.text "Create the admin account to get started." ]
             , Ui.input "Username" model.form.username UsernameChanged
             , Ui.passwordInput "Password" model.form.password PasswordChanged
             ]
                ++ errorView model.error
                ++ [ Ui.submitButton model.submitting "Create Admin" "Creating..." Submitted ]
            )
        )


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
