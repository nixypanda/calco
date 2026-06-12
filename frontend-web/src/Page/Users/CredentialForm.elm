module Page.Users.CredentialForm exposing
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
import Element.Font as Font
import Ui
import Ui.Theme exposing (Theme)


type alias Form =
    { username : String
    , password : String
    }


type Model
    = Editing Form
    | Invalid Form String
    | Submitting Form
    | Failed Form String


type Msg
    = UsernameChanged String
    | PasswordChanged String
    | Submitted


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


view :
    Config request
    -> { model : Model, device : Device, theme : Theme }
    -> Element Msg
view config { model, device, theme } =
    let
        form : Form
        form =
            currentForm model

        outerPadding : Int
        outerPadding =
            if Ui.isSmall device then
                16

            else
                24
    in
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 420)
        , Element.padding outerPadding
        ]
        (Ui.card theme
            ([ Ui.pageTitle theme device "CalCo"
             , Ui.subsectionTitle theme device config.title
             ]
                ++ descriptionView theme config.description
                ++ [ Ui.input theme
                        { label = "Username"
                        , value = form.username
                        , onChange = UsernameChanged
                        }
                   , Ui.passwordInput theme
                        { label = "Password"
                        , value = form.password
                        , onChange = PasswordChanged
                        }
                   , Ui.maybeErrorBanner theme (errorMessage model)
                   , Ui.primarySubmitButton device
                        theme
                        { state = Ui.submittingOrIdle (isSubmitting model)
                        , idleLabel = config.submitLabel
                        , submittingLabel = config.submittingLabel
                        , onPress = Submitted
                        }
                   ]
            )
        )


descriptionView : Theme -> Maybe String -> List (Element Msg)
descriptionView theme maybeDescription =
    case maybeDescription of
        Just description ->
            [ Element.paragraph
                [ Ui.body
                , Font.color theme.textMedium
                ]
                [ Element.text description ]
            ]

        Nothing ->
            []


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
