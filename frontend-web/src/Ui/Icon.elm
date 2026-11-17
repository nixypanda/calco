module Ui.Icon exposing (Icon(..), view)

import Element exposing (Element)
import Html.Attributes
import Svg exposing (Svg, circle, line, path, polyline, rect, svg)
import Svg.Attributes as SvgA
import Ui.Common exposing (toCssColor)


type Icon
    = Home
    | Search
    | Box
    | Utensils
    | Library
    | Settings
    | Key
    | Menu
    | ChevronLeft
    | ChevronRight
    | ChevronUp
    | ChevronDown
    | Plus
    | Close
    | Check
    | SearchX
    | Calendar
    | Pencil
    | System
    | Sun
    | Moon


view : { icon : Icon, size : Int, color : Element.Color } -> Element msg
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
            [ path [ SvgA.d "M4 10.5 12 4l8 6.5" ] [], path [ SvgA.d "M6.5 9.5V20h11V9.5" ] [] ]

        Search ->
            [ circle [ SvgA.cx "11", SvgA.cy "11", SvgA.r "6" ] []
            , line [ SvgA.x1 "16", SvgA.y1 "16", SvgA.x2 "20", SvgA.y2 "20" ] []
            ]

        SearchX ->
            [ circle [ SvgA.cx "11", SvgA.cy "11", SvgA.r "6" ] []
            , line [ SvgA.x1 "16", SvgA.y1 "16", SvgA.x2 "20", SvgA.y2 "20" ] []
            , line [ SvgA.x1 "8", SvgA.y1 "8", SvgA.x2 "14", SvgA.y2 "14" ] []
            , line [ SvgA.x1 "14", SvgA.y1 "8", SvgA.x2 "8", SvgA.y2 "14" ] []
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

        Library ->
            [ path [ SvgA.d "M4 4h5v16H4Z" ] []
            , path [ SvgA.d "M10 4h5v16h-5Z" ] []
            , path [ SvgA.d "M16 5l4-1v15l-4 1Z" ] []
            ]

        Settings ->
            [ line [ SvgA.x1 "4", SvgA.y1 "7", SvgA.x2 "20", SvgA.y2 "7" ] []
            , line [ SvgA.x1 "4", SvgA.y1 "12", SvgA.x2 "20", SvgA.y2 "12" ] []
            , line [ SvgA.x1 "4", SvgA.y1 "17", SvgA.x2 "20", SvgA.y2 "17" ] []
            , circle [ SvgA.cx "9", SvgA.cy "7", SvgA.r "2" ] []
            , circle [ SvgA.cx "15", SvgA.cy "12", SvgA.r "2" ] []
            , circle [ SvgA.cx "8", SvgA.cy "17", SvgA.r "2" ] []
            ]

        Key ->
            [ circle [ SvgA.cx "8", SvgA.cy "8", SvgA.r "4" ] []
            , path [ SvgA.d "M11 11 20 20" ] []
            , path [ SvgA.d "M16 16l3-3" ] []
            , path [ SvgA.d "M13 13l2-2" ] []
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

        Check ->
            [ polyline [ SvgA.points "5 13 10 18 19 7" ] [] ]

        Calendar ->
            [ path [ SvgA.d "M8 2v4M16 2v4M3 10h18" ] []
            , path
                [ SvgA.d
                    ("M5 4h14a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2"
                        ++ "H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z"
                    )
                ]
                []
            ]

        Pencil ->
            [ path [ SvgA.d "M12 20h9" ] []
            , path [ SvgA.d "M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" ] []
            ]

        System ->
            [ rect
                [ SvgA.x "3"
                , SvgA.y "4"
                , SvgA.width "18"
                , SvgA.height "12"
                , SvgA.rx "2"
                ]
                []
            , line [ SvgA.x1 "8", SvgA.y1 "20", SvgA.x2 "16", SvgA.y2 "20" ] []
            , line [ SvgA.x1 "12", SvgA.y1 "16", SvgA.x2 "12", SvgA.y2 "20" ] []
            ]

        Sun ->
            [ circle [ SvgA.cx "12", SvgA.cy "12", SvgA.r "4" ] []
            , line [ SvgA.x1 "12", SvgA.y1 "2", SvgA.x2 "12", SvgA.y2 "4" ] []
            , line [ SvgA.x1 "12", SvgA.y1 "20", SvgA.x2 "12", SvgA.y2 "22" ] []
            , line [ SvgA.x1 "4.22", SvgA.y1 "4.22", SvgA.x2 "5.64", SvgA.y2 "5.64" ] []
            , line [ SvgA.x1 "18.36", SvgA.y1 "18.36", SvgA.x2 "19.78", SvgA.y2 "19.78" ] []
            , line [ SvgA.x1 "2", SvgA.y1 "12", SvgA.x2 "4", SvgA.y2 "12" ] []
            , line [ SvgA.x1 "20", SvgA.y1 "12", SvgA.x2 "22", SvgA.y2 "12" ] []
            , line [ SvgA.x1 "4.22", SvgA.y1 "19.78", SvgA.x2 "5.64", SvgA.y2 "18.36" ] []
            , line [ SvgA.x1 "18.36", SvgA.y1 "5.64", SvgA.x2 "19.78", SvgA.y2 "4.22" ] []
            ]

        Moon ->
            [ path [ SvgA.d "M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11Z" ] [] ]
