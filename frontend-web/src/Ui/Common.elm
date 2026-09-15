module Ui.Common exposing
    ( hoverEffect
    , isSmall
    , minWidthZero
    , toCssColor
    , uiClass
    )

import Element exposing (Device)
import Html.Attributes


isSmall : Device -> Bool
isSmall device =
    device.class == Element.Phone


hoverEffect : Device -> List Element.Decoration -> Element.Attribute msg
hoverEffect device attrs =
    if isSmall device then
        Element.mouseOver []

    else
        Element.mouseOver attrs


uiClass : String -> Element.Attribute msg
uiClass className =
    Element.htmlAttribute (Html.Attributes.class className)


minWidthZero : Element.Attribute msg
minWidthZero =
    Element.htmlAttribute (Html.Attributes.style "min-width" "0")


toCssColor : Element.Color -> String
toCssColor color =
    let
        { red, green, blue, alpha } =
            Element.toRgb color
    in
    "rgba("
        ++ String.fromInt (round (red * 255))
        ++ ", "
        ++ String.fromInt (round (green * 255))
        ++ ", "
        ++ String.fromInt (round (blue * 255))
        ++ ", "
        ++ String.fromFloat alpha
        ++ ")"
