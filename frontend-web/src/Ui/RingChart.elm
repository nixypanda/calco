module Ui.RingChart exposing
    ( Segment
    , view
    )

import Element exposing (Element)
import Html exposing (Html)
import Html.Attributes as Attr
import Ui.Common as UiCommon


type alias Segment =
    { color : Element.Color, value : Float }


view :
    { size : Int
    , thickness : Int
    , gap : Float
    , segments : List Segment
    , emptyColor : Element.Color
    , centerColor : Element.Color
    , label : String
    , center : Html msg
    }
    -> Element msg
view config =
    Element.html
        (Html.div
            [ Attr.style "width" (String.fromInt config.size ++ "px")
            , Attr.style "height" (String.fromInt config.size ++ "px")
            , Attr.style "border-radius" "50%"
            , Attr.style "background" (gradient config)
            , Attr.style "display" "grid"
            , Attr.style "place-items" "center"
            , Attr.attribute "role" "img"
            , Attr.attribute "aria-label" config.label
            ]
            [ Html.div
                [ Attr.style "width"
                    ("calc(100% - " ++ String.fromInt (config.thickness * 2) ++ "px)")
                , Attr.style "height"
                    ("calc(100% - " ++ String.fromInt (config.thickness * 2) ++ "px)")
                , Attr.style "border-radius" "50%"
                , Attr.style "background" (UiCommon.toCssColor config.centerColor)
                , Attr.style "display" "grid"
                , Attr.style "place-items" "center"
                ]
                [ config.center ]
            ]
        )


gradient :
    { config
        | size : Int
        , gap : Float
        , segments : List Segment
        , emptyColor : Element.Color
    }
    -> String
gradient config =
    let
        positiveSegments : List Segment
        positiveSegments =
            List.filter (.value >> (\value -> value > 0)) config.segments

        total : Float
        total =
            List.sum (List.map .value positiveSegments)

        radius : Float
        radius =
            toFloat config.size / 2

        gapSize : Float
        gapSize =
            config.gap / (2 * pi * radius) * 100

        step : Segment -> ( Float, List String ) -> ( Float, List String )
        step segment ( offset, rendered ) =
            let
                next : Float
                next =
                    offset + segment.value / total * 100

                start : Float
                start =
                    offset + gapSize / 2

                finish : Float
                finish =
                    next - gapSize / 2

                color : String
                color =
                    UiCommon.toCssColor segment.color
            in
            ( next
            , if finish > start then
                rendered
                    ++ [ color ++ " " ++ String.fromFloat start ++ "%"
                       , color ++ " " ++ String.fromFloat finish ++ "%"
                       , "transparent " ++ String.fromFloat finish ++ "%"
                       , "transparent " ++ String.fromFloat (next + gapSize / 2) ++ "%"
                       ]

              else
                rendered
            )

        stops : List String
        stops =
            positiveSegments |> List.foldl step ( 0, [] ) |> Tuple.second
    in
    if total <= 0 || List.isEmpty stops then
        UiCommon.toCssColor config.emptyColor

    else
        "conic-gradient(" ++ String.join ", " stops ++ ")"
