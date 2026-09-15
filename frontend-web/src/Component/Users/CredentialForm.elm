module Component.Users.CredentialForm exposing
    ( Config
    , Form
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , init
    , markFailed
    , update
    , view
    )

import Element exposing (Device, Element)
import Ui
import Ui.Button as Button
import Ui.DesignTokens as DesignTokens
import Ui.Input as UiInput
import Ui.Theme exposing (Theme)
import Ui.Typography as Typography



-- MODEL


type alias Form =
    { username : String
    , password : String
    }


type Model
    = Editing Form
    | Invalid Form String
    | Submitting Form
    | Failed Form String


type OutMsg request
    = NoOp
    | RequestSubmit request


type alias Config request =
    { validate : Form -> Result String request
    , title : String
    , description : Maybe String
    , submitLabel : String
    , submittingLabel : String
    }


init : Model
init =
    Editing { username = "", password = "" }



-- UPDATE


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Submitted


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


update : Config request -> Msg -> Model -> ( Model, OutMsg request )
update config msg model =
    let
        form : Form
        form =
            currentForm model
    in
    case msg of
        UsernameChanged username ->
            ( Editing { form | username = username }, NoOp )

        PasswordChanged password ->
            ( Editing { form | password = password }, NoOp )

        Submitted ->
            case config.validate form of
                Ok request ->
                    ( Submitting form, RequestSubmit request )

                Err message ->
                    ( Invalid form message, NoOp )


markFailed : String -> Model -> Model
markFailed message model =
    case model of
        Submitting form ->
            Failed form message

        _ ->
            model



-- VIEW


view :
    Config request
    -> { model : Model, device : Device, theme : Theme }
    -> Element Msg
view config { model, device, theme } =
    let
        form : Form
        form =
            currentForm model
    in
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 420)
        , Element.padding DesignTokens.space16
        ]
        (Element.column
            [ Element.width Element.fill
            , Element.spacing DesignTokens.space16
            ]
            [ Ui.card theme
                [ Typography.subsectionTitle theme config.title
                , Typography.maybeMutedParagraph theme config.description
                , UiInput.input theme
                    { label = "Username"
                    , value = form.username
                    , onChange = UsernameChanged
                    }
                , UiInput.passwordInput theme
                    { label = "Password"
                    , value = form.password
                    , onChange = PasswordChanged
                    }
                , Ui.maybeErrorBanner theme (errorMessage model)
                ]
            , Button.textButton device
                theme
                { tone = Button.Primary
                , width = Button.FullWidth
                , label = config.submitLabel
                , onPress = Submitted
                , submitState = Just (Button.submittingOrIdle (isSubmitting model))
                , submittingLabel = Just config.submittingLabel
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


errorMessage : Model -> Maybe String
errorMessage model =
    case model of
        Invalid _ message ->
            Just message

        Failed _ message ->
            Just message

        _ ->
            Nothing
