module View.Charts exposing (linearProgress, verticalBarChart)

{-| Chart-style visual primitives.

This module hosts rendering helpers that lean on visualisation concepts
(progress bars, bar charts) so `Ui` can stay focused on layout primitives
without growing into a kitchen sink. `Ui` re-exports `linearProgress` so
callers can use either path.

-}

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border


{-| A 10px-tall pill progress bar. The track uses the `inputFill` token
and the fill color is provided by the caller.
-}
linearProgress :
    { value : Float
    , max : Float
    , color : Element.Color
    }
    -> Element msg
linearProgress config =
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
        , Background.color (Element.rgb255 244 246 248)
        , Border.rounded 999
        , Element.clip
        ]
        [ Element.el
            [ Element.width (Element.fillPortion filled)
            , Element.height Element.fill
            , Background.color config.color
            , Border.rounded 999
            ]
            Element.none
        , Element.el [ Element.width (Element.fillPortion remaining) ] Element.none
        ]


{-| A stub vertical bar chart. Renders 5–7 colored bars above a thin
baseline. Reserved for a future "activity by day" view; see
`docs/visual-reskin.md` §12.
-}
verticalBarChart :
    List
        { label : String
        , value : Float
        , color : Element.Color
        }
    -> Element msg
verticalBarChart bars =
    let
        barWidth : Int
        barWidth =
            18

        barGap : Int
        barGap =
            6

        baseline : Element msg
        baseline =
            Element.el
                [ Element.width Element.fill
                , Element.height (Element.px 1)
                , Background.color (Element.rgb255 232 234 238)
                ]
                Element.none

        barElement : { label : String, value : Float, color : Element.Color } -> Element msg
        barElement bar =
            Element.el
                [ Element.width (Element.px barWidth)
                , Element.height (Element.px (max 4 (round bar.value)))
                , Background.color bar.color
                , Border.rounded 4
                ]
                Element.none
    in
    Element.column [ Element.spacing 6 ]
        [ Element.row [ Element.spacing barGap ]
            (List.map barElement bars)
        , baseline
        ]
