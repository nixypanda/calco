module Page.Auth.CredentialCard exposing (credentialCard)

import Element exposing (Device, Element)
import Element.Font as Font
import Ui
import Ui.Theme exposing (Theme)


credentialCard :
    { device : Device
    , theme : Theme
    , title : String
    , description : Maybe String
    , username : String
    , password : String
    , onUsernameChanged : String -> msg
    , onPasswordChanged : String -> msg
    , error : Maybe String
    , submitting : Bool
    , submitLabel : String
    , submittingLabel : String
    , onSubmit : msg
    }
    -> Element msg
credentialCard config =
    let
        theme : Theme
        theme =
            config.theme

        outerPadding : Int
        outerPadding =
            if Ui.isSmall config.device then
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
            ([ Ui.pageTitle theme "CalCo"
             , Ui.subsectionTitle theme config.title
             ]
                ++ descriptionView theme config.description
                ++ [ Ui.input theme "Username" config.username config.onUsernameChanged
                   , Ui.passwordInput theme "Password" config.password config.onPasswordChanged
                   , Ui.maybeErrorBanner theme config.error
                   , Ui.primarySubmitButton theme
                        config.submitting
                        config.submitLabel
                        config.submittingLabel
                        config.onSubmit
                   ]
            )
        )


descriptionView : Theme -> Maybe String -> List (Element msg)
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
