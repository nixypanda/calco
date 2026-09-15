module Ui.Feedback exposing
    ( emptyState
    , errorBanner
    , infoBanner
    , linearProgress
    , loading
    , maybeErrorBanner
    , modalOverlay
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui.DesignTokens exposing (radiusControl, radiusPill, space12, space8)
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography exposing (sectionTitle, uiClass)


loading : Theme -> String -> Element msg
loading theme message =
    Element.el
        [ Font.color theme.textMuted ]
        (Element.text message)


emptyState : Theme -> String -> Element msg
emptyState theme message =
    Surface.card theme
        [ Element.paragraph
            [ Font.color theme.textMuted
            , Font.center
            , Element.padding space8
            ]
            [ Element.text message ]
        ]


maybeErrorBanner : Theme -> Maybe String -> Element msg
maybeErrorBanner theme maybeError =
    Maybe.withDefault Element.none (Maybe.map (errorBanner theme) maybeError)


errorBanner : Theme -> String -> Element msg
errorBanner theme message =
    Element.paragraph
        [ Background.color theme.dangerBg
        , Font.color theme.dangerFg
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        [ Element.text message ]


infoBanner : Theme -> String -> Element msg
infoBanner theme message =
    Element.paragraph
        [ Background.color theme.brandBlueSoft
        , Font.color theme.textPrimary
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        [ Element.text message ]


modalOverlay :
    Theme
    ->
        { title : String
        , body : List (Element msg)
        , actions : Element msg
        , onBackgroundPress : Maybe msg
        }
    -> Element msg
modalOverlay theme config =
    let
        modalCard : Element msg
        modalCard =
            Element.el
                [ Element.centerX
                , Element.centerY
                , Element.width (Element.fill |> Element.maximum 480)
                , Element.padding 16
                , uiClass "ui-modal-card"
                ]
                (Surface.card theme
                    (sectionTitle theme config.title
                        :: config.body
                        ++ [ config.actions ]
                    )
                )
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.inFront modalCard
        ]
        (Input.button
            [ Element.width Element.fill
            , Element.height Element.fill
            , Background.color (Element.rgba255 0 0 0 0.28)
            , uiClass "ui-modal-backdrop"
            ]
            { onPress = config.onBackgroundPress
            , label = Element.none
            }
        )


linearProgress :
    Theme
    ->
        { value : Float
        , max : Float
        , color : Element.Color
        }
    -> Element msg
linearProgress theme config =
    let
        pct : Float
        pct =
            if config.max > 0 then
                min 1.0 (config.value / config.max)

            else
                0

        filled : Int
        filled =
            max 0 (round (pct * 100))

        remaining : Int
        remaining =
            max 0 (100 - filled)
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 10)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , Element.clip
        ]
        [ Element.el
            [ Element.width (Element.fillPortion filled)
            , Element.height Element.fill
            , Background.color config.color
            , Border.rounded radiusPill
            ]
            Element.none
        , Element.el [ Element.width (Element.fillPortion remaining) ] Element.none
        ]
