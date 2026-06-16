module View.Charts exposing (verticalBarChart)

{-| Chart-style visual primitives.

This module hosts rendering helpers that lean on visualisation concepts
(bar charts for now) so `Ui` can stay focused on layout primitives
without growing into a kitchen sink.

-}

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Ui


{-| A stub vertical bar chart. Renders 5–7 colored bars above a thin
baseline. Reserved for a future "activity by day" view; see
`docs/visual-reskin.md` §12.
-}
verticalBarChart :
    { baselineColor : Element.Color }
    ->
        List
            { label : String
            , value : Float
            , color : Element.Color
            }
    -> Element msg
verticalBarChart config bars =
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
                , Background.color config.baselineColor
                ]
                Element.none

        barElement : { label : String, value : Float, color : Element.Color } -> Element msg
        barElement bar =
            Element.el
                [ Element.width (Element.px barWidth)
                , Element.height (Element.px (max 4 (round bar.value)))
                , Background.color bar.color
                , Border.rounded Ui.radiusTight
                ]
                Element.none
    in
    Element.column [ Element.spacing Ui.space8 ]
        [ Element.row [ Element.spacing barGap ]
            (List.map barElement bars)
        , baseline
        ]
