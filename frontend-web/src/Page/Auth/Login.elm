module Page.Auth.Login exposing
    ( Form
    , Model
    , Msg(..)
    , OutMsg(..)
    , Problem(..)
    , State(..)
    , currentForm
    , init
    , loginPayload
    , update
    , view
    )

import Api.Client as Client
import Data.Auth as Auth
import Element exposing (Element)
import Element.Font as Font
import Lib.Text as Text
import Ui


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
    | PasswordRequired


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
            case loginPayload form of
                Ok request ->
                    ( { model | state = Submitting form }
                    , Cmd.none
                    , RequestLogin request
                    )

                Err problem ->
                    ( { model | state = Invalid form problem }, Cmd.none, NoOp )

        LoginCompleted result ->
            case model.state of
                Submitting form ->
                    case result of
                        Ok loginSession ->
                            ( model, Cmd.none, LoginSucceeded loginSession )

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
             , Ui.input "Username" form.username UsernameChanged
             , Ui.passwordInput "Password" form.password PasswordChanged
             ]
                ++ errorView model.state
                ++ [ Ui.submitButton (isSubmitting model.state) "Log In" "Logging in..." Submitted ]
            )
        )


isSubmitting : State -> Bool
isSubmitting state =
    case state of
        Submitting _ ->
            True

        _ ->
            False


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

        PasswordRequired ->
            "Password is required"
