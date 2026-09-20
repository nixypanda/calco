module Ui.Skeleton exposing
    ( bar
    , barCustom
    , button
    , card
    , input
    , listRow
    , loading
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Ui.Common exposing (uiClass)
import Ui.DesignTokens
    exposing
        ( radiusControl
        , radiusPill
        , radiusSmall
        , space16
        , space2
        , space4
        , space8
        )
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)


loading : Theme -> Element msg
loading theme =
    Element.column [ Element.width Element.fill, Element.spacing space16 ]
        [ bar theme
        , bar theme
        , bar theme
        ]


bar : Theme -> Element msg
bar theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 16)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        ]
        Element.none


barCustom : Theme -> { width : Element.Length, height : Int } -> Element msg
barCustom theme config =
    Element.el
        [ Element.width config.width
        , Element.height (Element.px config.height)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        ]
        Element.none


circle : Theme -> Element msg
circle theme =
    Element.el
        [ Element.width (Element.px 12)
        , Element.height (Element.px 12)
        , Background.color theme.inputFill
        , Border.rounded 999
        , uiClass "ui-skeleton"
        ]
        Element.none


input : Theme -> Element msg
input theme =
    Element.column
        [ Element.width Element.fill
        , Element.spacing space4
        ]
        [ Element.el
            [ Element.width (Element.px 80)
            , Element.height (Element.px 12)
            , Background.color theme.inputFill
            , Border.rounded radiusSmall
            , uiClass "ui-skeleton"
            ]
            Element.none
        , Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 48)
            , Background.color theme.inputFill
            , Border.rounded radiusControl
            , uiClass "ui-skeleton"
            ]
            Element.none
        ]


button : Theme -> Element msg
button theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 48)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , uiClass "ui-skeleton"
        ]
        Element.none


listRow : Theme -> Element msg
listRow theme =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.padding space16
        , Element.spacing space8
        ]
        [ Element.el
            [ Element.width (Element.px 12)
            , Element.alignTop
            , Element.paddingEach { top = space2, right = 0, bottom = 0, left = 0 }
            ]
            (circle theme)
        , Element.column
            [ Element.width Element.fill
            , Element.spacing space4
            , Element.alignTop
            ]
            [ Element.el
                [ Element.width (Element.fillPortion 2)
                , Element.height (Element.px 16)
                , Background.color theme.inputFill
                , Border.rounded radiusSmall
                , uiClass "ui-skeleton"
                ]
                Element.none
            , Element.el
                [ Element.width (Element.fillPortion 3)
                , Element.height (Element.px 12)
                , Background.color theme.inputFill
                , Border.rounded radiusSmall
                , uiClass "ui-skeleton"
                ]
                Element.none
            ]
        ]


card : Theme -> { rows : Int } -> Element msg
card theme config =
    Surface.card theme
        (List.map (\_ -> bar theme)
            (List.range 1 (max 1 config.rows))
        )
