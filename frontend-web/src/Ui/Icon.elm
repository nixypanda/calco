module Ui.Icon exposing (Icon(..), view)

import Element exposing (Element)
import Html.Attributes
import Svg exposing (Svg, circle, line, path, polyline, svg)
import Svg.Attributes as SvgA


type Icon
    = Home
    | Search
    | Box
    | Utensils
    | Menu
    | ChevronLeft
    | ChevronRight
    | ChevronUp
    | ChevronDown
    | Plus
    | Close


view :
    { icon : Icon
    , size : Int
    , color : Element.Color
    }
    -> Element msg
view config =
    Element.el
        [ Element.width (Element.px config.size)
        , Element.height (Element.px config.size)
        , Element.centerX
        , Element.centerY
        ]
        (Element.html
            (svg
                [ SvgA.viewBox "0 0 24 24"
                , SvgA.width (String.fromInt config.size)
                , SvgA.height (String.fromInt config.size)
                , SvgA.fill "none"
                , SvgA.stroke (toCssColor config.color)
                , SvgA.strokeWidth "2"
                , SvgA.strokeLinecap "round"
                , SvgA.strokeLinejoin "round"
                , Html.Attributes.style "display" "block"
                , Html.Attributes.attribute "aria-hidden" "true"
                , Html.Attributes.attribute "focusable" "false"
                ]
                (shapes config.icon)
            )
        )


shapes : Icon -> List (Svg msg)
shapes icon =
    case icon of
        Home ->
            [ path [ SvgA.d "M4 10.5 12 4l8 6.5" ] []
            , path [ SvgA.d "M6.5 9.5V20h11V9.5" ] []
            ]

        Search ->
            [ circle [ SvgA.cx "11", SvgA.cy "11", SvgA.r "6" ] []
            , line [ SvgA.x1 "16", SvgA.y1 "16", SvgA.x2 "20", SvgA.y2 "20" ] []
            ]

        Box ->
            [ path [ SvgA.d "M12 3 19 7 12 11 5 7Z" ] []
            , path [ SvgA.d "M5 7v10l7 4 7-4V7" ] []
            , path [ SvgA.d "M12 11v10" ] []
            ]

        Utensils ->
            [ path [ SvgA.d "M3 2v7a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2V2" ] []
            , path [ SvgA.d "M7 2v20" ] []
            , path [ SvgA.d "M21 15V2a5 5 0 0 0-5 5v6a2 2 0 0 0 2 2h3Zm0 0v7" ] []
            ]

        Menu ->
            [ line [ SvgA.x1 "5", SvgA.y1 "7", SvgA.x2 "19", SvgA.y2 "7" ] []
            , line [ SvgA.x1 "5", SvgA.y1 "12", SvgA.x2 "19", SvgA.y2 "12" ] []
            , line [ SvgA.x1 "5", SvgA.y1 "17", SvgA.x2 "19", SvgA.y2 "17" ] []
            ]

        ChevronLeft ->
            [ polyline [ SvgA.points "15 6 9 12 15 18" ] [] ]

        ChevronRight ->
            [ polyline [ SvgA.points "9 6 15 12 9 18" ] [] ]

        ChevronUp ->
            [ polyline [ SvgA.points "6 15 12 9 18 15" ] [] ]

        ChevronDown ->
            [ polyline [ SvgA.points "6 9 12 15 18 9" ] [] ]

        Plus ->
            [ line [ SvgA.x1 "12", SvgA.y1 "5", SvgA.x2 "12", SvgA.y2 "19" ] []
            , line [ SvgA.x1 "5", SvgA.y1 "12", SvgA.x2 "19", SvgA.y2 "12" ] []
            ]

        Close ->
            [ line [ SvgA.x1 "6", SvgA.y1 "6", SvgA.x2 "18", SvgA.y2 "18" ] []
            , line [ SvgA.x1 "18", SvgA.y1 "6", SvgA.x2 "6", SvgA.y2 "18" ] []
            ]


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
