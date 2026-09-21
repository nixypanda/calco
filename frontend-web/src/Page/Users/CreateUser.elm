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
import I18n
import Lib.Text as Text
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Feedback as Feedback
import Ui.Input as UiInput
import Ui.Page as UiPage
import Ui.Surface as Surface
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


view : { model : Model, device : Device, theme : Theme, language : Language } -> Element Msg
view { model, device, theme, language } =
    let
        form : Form
        form =
            currentForm model
    in
    UiPage.pageContainer
        (errorView theme language model
            ++ [ Surface.formSection theme
                    (I18n.t language TidUsersCredentials)
                    [ UiInput.input theme
                        { label = I18n.t language TidCommonUsername
                        , value = form.username
                        , onChange = UsernameChanged
                        }
                    , UiInput.input theme
                        { label = I18n.t language TidCommonDisplayName
                        , value = form.displayName
                        , onChange = DisplayNameChanged
                        }
                    , UiInput.passwordInput theme
                        { label = I18n.t language TidUsersInitialPassword
                        , value = form.initialPassword
                        , onChange = PasswordChanged
                        }
                    ]
               , Button.textButton device
                    theme
                    { tone = Button.Primary
                    , width = Button.FullWidth
                    , label = I18n.t language TidCommonSave
                    , onPress = Submitted
                    , submitState = Just (Button.submittingOrIdle (isSubmitting model))
                    , submittingLabel = Just (I18n.t language TidCommonSaving)
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


errorView : Theme -> Language -> Model -> List (Element msg)
errorView theme language model =
    case model of
        Invalid _ problem ->
            [ Feedback.errorBanner theme (problemMessage language problem) ]

        Failed _ message ->
            [ Feedback.errorBanner theme message ]

        _ ->
            []


problemMessage : Language -> Problem -> String
problemMessage language problem =
    case problem of
        UsernameRequired ->
            I18n.t language TidCommonUsernameRequired

        DisplayNameRequired ->
            I18n.t language TidUsersDisplayNameRequired

        InitialPasswordRequired ->
            I18n.t language TidUsersInitialPasswordRequired
