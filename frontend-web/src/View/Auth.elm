module View.Auth exposing (credentialCard)

import Element exposing (Device, Element)
import Element.Font as Font
import Element.Region as Region
import Ui


credentialCard :
    { device : Device
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
        (Ui.card
            ([ Element.el [ Ui.display, Font.bold, Region.heading 1 ] (Element.text "CalCo")
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
                   , Ui.maybeErrorBanner config.error
                   , Ui.submitButton
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
