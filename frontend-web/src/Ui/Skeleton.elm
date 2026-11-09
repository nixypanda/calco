module Ui.Skeleton exposing
    ( bar
    , barCustom
    , busy
    , button
    , buttonWithAttributes
    , card
    , elLine
    , input
    , listRow
    , paragraphLine
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Ui.Common exposing (dataAttribute, skeletonRegion, testId, uiClass)
import Ui.DesignTokens
    exposing
        ( radiusControl
        , radiusPill
        , radiusSmall
        , space12
        , space16
        , space2
        , space4
        )
import Ui.Surface as Surface
import Ui.Theme exposing (Theme)


{-| The page-level loading wrapper. It owns the one `role="status"` per pane
and the visually hidden label; the persistent page root owns `aria-busy`. The
root's `aria-busy` is the primary loading signal; this status label is the
secondary announcement. The decorative skeleton subtree is hidden from
assistive technology so the status announces one loading message instead of an
empty element tree.
-}
busy : { label : String } -> List (Element msg) -> Element msg
busy config children =
    Element.column
        [ Element.width Element.fill
        , dataAttribute "role" "status"
        , dataAttribute "data-skeleton-page" "true"
        , skeletonRegion
        ]
        [ Element.el [ uiClass "ui-visually-hidden" ] (Element.text config.label)
        , Element.el
            [ Element.width Element.fill
            , dataAttribute "aria-hidden" "true"
            ]
            (Element.column [ Element.width Element.fill, Element.spacing space12 ] children)
        ]


{-| A bar exactly `size` pixels high, mirroring an elm-ui text line.
-}
elLine : Theme -> { size : Int, width : Element.Length } -> Element msg
elLine theme config =
    Element.el
        [ Element.width config.width
        , Element.height (Element.px config.size)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        , skeletonRegion
        ]
        Element.none


{-| A bar exactly `size + spacing` pixels high, mirroring an elm-ui paragraph
line whose default spacing is 5.
-}
paragraphLine : Theme -> { size : Int, spacing : Int, width : Element.Length } -> Element msg
paragraphLine theme config =
    elLine theme { size = config.size + config.spacing, width = config.width }


bar : Theme -> Element msg
bar theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 16)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        , skeletonRegion
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
        , skeletonRegion
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
        , skeletonRegion
        , testId "field"
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
            , testId "field-control"
            ]
            Element.none
        ]


button : Theme -> Element msg
button theme =
    buttonWithAttributes theme []


buttonWithAttributes : Theme -> List (Element.Attribute msg) -> Element msg
buttonWithAttributes theme extraAttrs =
    Element.el
        ([ Element.width Element.fill
         , Element.height (Element.px 48)
         , Background.color theme.inputFill
         , Border.rounded radiusPill
         , uiClass "ui-skeleton"
         , skeletonRegion
         ]
            ++ extraAttrs
        )
        Element.none


listRow : Theme -> Element msg
listRow theme =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.padding space16
        , Element.spacing space12
        , skeletonRegion
        , testId "list-row"
        ]
        [ Element.el
            [ Element.width (Element.px 12)
            , Element.alignTop
            , Element.paddingEach { top = space2, right = 0, bottom = 0, left = 0 }
            ]
            (circle theme)
        , Element.column [ Element.width Element.fill, Element.spacing space4, Element.alignTop ]
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
    Element.el
        [ Element.width Element.fill, skeletonRegion ]
        (Surface.card theme
            (List.map (\_ -> bar theme) (List.range 1 (max 1 config.rows)))
        )
