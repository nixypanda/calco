module Ui.Feedback exposing
    ( blockingOverlay
    , emptyState
    , emptyStateWithIcon
    , errorBanner
    , errorRetry
    , infoBanner
    , linearProgress
    , loading
    , maybeErrorBanner
    , modalOverlay
    , warningBanner
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Button as Button
import Ui.Common exposing (uiClass)
import Ui.DesignTokens exposing (radiusControl, radiusPill, space12, space16, space8)
import Ui.Icon as Icon exposing (Icon)
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)
import Ui.Typography exposing (sectionTitle)


loading : Theme -> String -> Element msg
loading theme message =
    Element.el [ Font.color theme.textMuted ] (Element.text message)


emptyState : Theme -> String -> Element msg
emptyState theme message =
    Surface.card theme
        [ Element.paragraph
            [ Font.color theme.textMuted, Font.center, Element.padding space8 ]
            [ Element.text message ]
        ]


{-| Full-area empty state with an icon: fills the height its parent offers and
centers its content, for a whole result area that came back empty such as a
search that matched nothing.
-}
emptyStateWithIcon : Theme -> { icon : Icon, message : String } -> Element msg
emptyStateWithIcon theme config =
    Surface.cardFill theme
        [ Icon.view { icon = config.icon, size = 40, color = theme.textMuted }
        , Element.paragraph [ Font.color theme.textMuted, Font.center, Element.width Element.fill ]
            [ Element.text config.message ]
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


{-| Error banner with a retry action, for failed page loads.
-}
errorRetry : Theme -> Language -> Device -> { message : String, onRetry : msg } -> Element msg
errorRetry theme language device config =
    Surface.card theme
        [ errorBanner theme config.message
        , Button.textButton device
            theme
            { tone = Button.Primary
            , width = Button.FullWidth
            , label = I18n.t language TidUiRetry
            , onPress = config.onRetry
            , submitState = Nothing
            , submittingLabel = Nothing
            , trailing = Nothing
            }
        ]


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


{-| Amber banner for non-blocking warnings, such as incomplete data.
-}
warningBanner : Theme -> String -> Element msg
warningBanner theme message =
    Element.paragraph
        [ Background.color theme.warningBg
        , Font.color theme.warningFg
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        [ Element.text message ]


{-| A modal for work that must finish before the user can continue. It has no
footer or dismiss action, so nothing inside invites leaving early.
-}
blockingOverlay : Theme -> { title : String, body : List (Element msg) } -> Element msg
blockingOverlay theme config =
    modalScrim theme
        { card =
            modalCard theme { title = config.title, body = config.body, footer = Nothing }
        , onBackgroundPress = Nothing
        }


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
    modalScrim theme
        { card =
            modalCard theme
                { title = config.title
                , body = config.body
                , footer = Just config.actions
                }
        , onBackgroundPress = config.onBackgroundPress
        }


{-| The backdrop is a plain element when the dialog cannot be dismissed: a
button with no accessible name would still be reachable by keyboard.
-}
modalScrim : Theme -> { card : Element msg, onBackgroundPress : Maybe msg } -> Element msg
modalScrim theme config =
    let
        backdropAttrs : List (Element.Attribute msg)
        backdropAttrs =
            [ Element.width Element.fill
            , Element.height Element.fill
            , Background.color theme.scrim
            , uiClass "ui-modal-backdrop"
            ]

        backdrop : Element msg
        backdrop =
            case config.onBackgroundPress of
                Just onPress ->
                    Input.button backdropAttrs { onPress = Just onPress, label = Element.none }

                Nothing ->
                    Element.el backdropAttrs Element.none
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.inFront config.card
        ]
        backdrop


modalCard :
    Theme
    ->
        { title : String
        , body : List (Element msg)
        , footer : Maybe (Element msg)
        }
    -> Element msg
modalCard theme config =
    Element.el
        [ Element.centerX
        , Element.centerY
        , Element.width (Element.fill |> Element.maximum 480)
        , Element.padding space16
        , uiClass "ui-modal-card"
        , Element.htmlAttribute (Html.Attributes.attribute "role" "dialog")
        , Element.htmlAttribute (Html.Attributes.attribute "aria-modal" "true")
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" config.title)
        , Element.htmlAttribute (Html.Attributes.attribute "tabindex" "-1")
        ]
        (Surface.section theme
            { header = Just (sectionTitle theme config.title)
            , body = config.body
            , footer = config.footer
            }
        )


linearProgress : Theme -> { value : Float, max : Float, color : Element.Color } -> Element msg
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
