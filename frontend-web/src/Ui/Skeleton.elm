module Ui.Skeleton exposing
    ( bar
    , barCustom
    , busy
    , button
    , buttonWithAttributes
    , card
    , chipRow
    , elLine
    , field
    , fieldWithoutLabel
    , icon
    , input
    , listRow
    , paragraphLine
    , selectField
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
        , space8
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


{-| A 44px circular icon placeholder. Mirrors `Button.iconButton` and keeps
the date card's leading/trailing controls from shifting when the real icons
arrive.
-}
icon : Theme -> Element msg
icon theme =
    Element.el
        [ Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , uiClass "ui-skeleton"
        , skeletonRegion
        ]
        Element.none


{-| A labelled text-control placeholder. `gap` is the measured space between
the 13px label line and the 44px control: text inputs use 7 (64px wrapper),
suffix inputs use 4 (61px wrapper).
-}
field : Theme -> { labelWidth : Element.Length, gap : Int } -> Element msg
field theme config =
    fieldWithKind theme config Nothing


{-| A select/dropdown placeholder: label 13, 4px gap and a 44px trigger. The
explicit `data-field-kind="select"` marker lets the layout harness measure the
same control type instead of inferring it from spacing.
-}
selectField : Theme -> { labelWidth : Element.Length } -> Element msg
selectField theme config =
    fieldWithKind theme { labelWidth = config.labelWidth, gap = 4 } (Just "select")


{-| A control placeholder with no visible label. The loaded category input is
`Input.labelAbove` with an empty label, which measures as the label gap plus the
44px control (51px).
-}
fieldWithoutLabel : Theme -> { gap : Int } -> Element msg
fieldWithoutLabel theme config =
    Element.column
        [ Element.width Element.fill
        , Element.paddingEach
            { top = config.gap
            , right = 0
            , bottom = 0
            , left = 0
            }
        , skeletonRegion
        , testId "field"
        ]
        [ control theme ]


fieldWithKind : Theme -> { labelWidth : Element.Length, gap : Int } -> Maybe String -> Element msg
fieldWithKind theme config kind =
    Element.column
        ([ Element.width Element.fill
         , Element.spacing config.gap
         , skeletonRegion
         , testId "field"
         ]
            ++ (case kind of
                    Just value ->
                        [ dataAttribute "data-field-kind" value ]

                    Nothing ->
                        []
               )
        )
        [ Element.el
            [ Element.width config.labelWidth
            , Element.height (Element.px 13)
            , Background.color theme.inputFill
            , Border.rounded radiusSmall
            , uiClass "ui-skeleton"
            ]
            Element.none
        , control theme
        ]


control : Theme -> Element msg
control theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 44)
        , Background.color theme.inputFill
        , Border.rounded radiusControl
        , uiClass "ui-skeleton"
        , testId "field-control"
        ]
        Element.none


{-| The legacy 64px field wrapper. It now shares `field` geometry so every
call site gets the real 13px label and 44px control without changing the
measured outer height.
-}
input : Theme -> Element msg
input theme =
    field theme { labelWidth = Element.px 80, gap = 7 }


{-| A removable-chip placeholder: a 44px-tall target around a pill, matching
`Chip.removableChip`.
-}
chip : Theme -> Element msg
chip theme =
    Element.el
        [ Element.width (Element.px 80)
        , Element.height (Element.px 44)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , uiClass "ui-skeleton"
        , skeletonRegion
        ]
        Element.none


{-| A wrapped row of removable-chip placeholders.
-}
chipRow : Theme -> { count : Int } -> Element msg
chipRow theme config =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.paddingXY 0 space4
        , Element.spacing space8
        ]
        (List.repeat (max 0 config.count) (chip theme))


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
