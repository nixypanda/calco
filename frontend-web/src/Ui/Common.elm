module Ui.Common exposing
    ( dataAttribute
    , hoverEffect
    , isSmall
    , minWidthZero
    , skeletonRegion
    , testId
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


{-| Test-only seam: a stable hook for the browser layout harness.
-}
testId : String -> Element.Attribute msg
testId value =
    dataAttribute "data-testid" value


dataAttribute : String -> String -> Element.Attribute msg
dataAttribute name value =
    Element.htmlAttribute (Html.Attributes.attribute name value)


{-| Marks a skeleton subtree so loading regions are detectable in the DOM.
-}
skeletonRegion : Element.Attribute msg
skeletonRegion =
    dataAttribute "data-skeleton-region" "true"


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
