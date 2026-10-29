module Ui.Color exposing (mix, withAlpha)

import Element exposing (Color)


mix : Color -> Color -> Float -> Color
mix from to amount =
    let
        start : { red : Float, green : Float, blue : Float, alpha : Float }
        start =
            Element.toRgb from

        finish : { red : Float, green : Float, blue : Float, alpha : Float }
        finish =
            Element.toRgb to

        mixChannel : Float -> Float -> Float
        mixChannel a b =
            a + (b - a) * amount
    in
    Element.rgba (mixChannel start.red finish.red)
        (mixChannel start.green finish.green)
        (mixChannel start.blue finish.blue)
        (mixChannel start.alpha finish.alpha)


withAlpha : Float -> Color -> Color
withAlpha alpha color =
    let
        rgb : { red : Float, green : Float, blue : Float, alpha : Float }
        rgb =
            Element.toRgb color
    in
    Element.rgba rgb.red rgb.green rgb.blue alpha
