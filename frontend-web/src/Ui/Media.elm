module Ui.Media exposing (fadeOverlay, imageBackground)

import Element exposing (Element)
import Html.Attributes
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Theme as Theme exposing (Theme)


{-| Bottom-up fade that blends a fixed-height hero image into the card
background.
-}
fadeOverlay : Theme -> Element msg
fadeOverlay theme =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.htmlAttribute
            (Html.Attributes.style "background-image" (fadeGradient theme))
        ]
        Element.none


fadeGradient : Theme -> String
fadeGradient theme =
    case theme.mode of
        Theme.Light ->
            "linear-gradient(to bottom, "
                ++ "rgba(255,255,255,0) 0%, "
                ++ "rgba(255,255,255,0) 25%, "
                ++ "rgba(255,255,255,0.48) 85%, "
                ++ UiCommon.toCssColor theme.cardBg
                ++ " 100%)"

        Theme.Dark ->
            "linear-gradient(to bottom, "
                ++ "rgba(0,0,0,0.25) 0%, "
                ++ "rgba(0,0,0,0.55) 45%, "
                ++ "rgba(0,0,0,0.85) 75%, "
                ++ UiCommon.toCssColor theme.cardBg
                ++ " 100%)"


{-| Cover background for a fixed-height media header. The background is sized
against `DesignTokens.heroImageSpan` so it stays crisp on wide screens.
-}
imageBackground : { url : String, focusX : String } -> List (Element.Attribute msg)
imageBackground image =
    [ Element.htmlAttribute
        (Html.Attributes.style
            "background-image"
            ("url(\"" ++ image.url ++ "\")")
        )
    , Element.htmlAttribute
        (Html.Attributes.style
            "background-size"
            ("max(100%, " ++ String.fromInt DesignTokens.heroImageSpan ++ "px) auto")
        )
    , Element.htmlAttribute
        (Html.Attributes.style
            "background-position"
            (image.focusX ++ " top")
        )
    , Element.htmlAttribute
        (Html.Attributes.style "background-repeat" "no-repeat")
    ]
