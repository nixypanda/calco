module Ui.DesignTokens exposing
    ( accentPink
    , accentSoftGreen
    , accentYellow
    , radiusCard
    , radiusControl
    , radiusHairline
    , radiusHero
    , radiusPill
    , radiusSmall
    , radiusTight
    , space12
    , space16
    , space2
    , space20
    , space24
    , space4
    , space8
    )

import Element


accentPink : Element.Color
accentPink =
    Element.rgb255 255 138 170


accentYellow : Element.Color
accentYellow =
    Element.rgb255 255 210 80


accentSoftGreen : Element.Color
accentSoftGreen =
    Element.rgb255 200 235 200



-- Spacing scale


space2 : Int
space2 =
    2


space4 : Int
space4 =
    4


space8 : Int
space8 =
    8


space12 : Int
space12 =
    12


space16 : Int
space16 =
    16


space20 : Int
space20 =
    20


space24 : Int
space24 =
    24



-- Border radius scale


radiusHairline : Int
radiusHairline =
    2


radiusTight : Int
radiusTight =
    4


radiusSmall : Int
radiusSmall =
    8


radiusControl : Int
radiusControl =
    12


radiusCard : Int
radiusCard =
    20


radiusHero : Int
radiusHero =
    24


radiusPill : Int
radiusPill =
    999
