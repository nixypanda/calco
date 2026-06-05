module View.Auth exposing (credentialCard)

import Element exposing (Element)
import Element.Font as Font
import Ui


credentialCard :
    { title : String
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
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 420)
        , Element.padding 24
        ]
        (Ui.card
            ([ Element.el [ Ui.display, Font.bold ] (Element.text "CalCo")
             , Element.el
                [ Ui.heading2
                , Font.medium
                , Font.color Ui.textMedium
                ]
                (Element.text config.title)
             ]
                ++ descriptionView config.description
                ++ [ Ui.input "Username" config.username config.onUsernameChanged
                   , Ui.passwordInput "Password" config.password config.onPasswordChanged
                   ]
                ++ errorView config.error
                ++ [ Ui.submitButton
                        config.submitting
                        config.submitLabel
                        config.submittingLabel
                        config.onSubmit
                   ]
            )
        )


descriptionView : Maybe String -> List (Element msg)
descriptionView maybeDescription =
    case maybeDescription of
        Just description ->
            [ Element.paragraph
                [ Ui.body
                , Font.color Ui.textMedium
                ]
                [ Element.text description ]
            ]

        Nothing ->
            []


errorView : Maybe String -> List (Element msg)
errorView maybeError =
    case maybeError of
        Just message ->
            [ Ui.errorBanner message ]

        Nothing ->
            []
