module Ui.Skeleton exposing
    ( badge
    , bar
    , barCustom
    , bottomActions
    , busy
    , button
    , buttonWithAttributes
    , categoryChipRow
    , checkboxRow
    , chipRow
    , dot
    , elLine
    , field
    , fieldWithoutLabel
    , icon
    , input
    , pageHeader
    , paragraphLine
    , row
    , searchField
    , selectField
    , stat
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Html exposing (Html)
import Html.Attributes
import Ui.Common exposing (dataAttribute, skeletonRegion, testId, toCssColor, uiClass)
import Ui.DesignTokens
    exposing
        ( radiusControl
        , radiusHairline
        , radiusPill
        , radiusSmall
        , space12
        , space2
        , space4
        , space8
        )
import Ui.Page as UiPage
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
line whose default spacing is 5. This models a line plus one inter-line gap; for
a single-line paragraph the measured line box is closer to `size + 1` (17px for
a 16px paragraph, 25px for a 24px paragraph), so use `elLine` with the measured
single-line height for one-line cases and `paragraphLine` for genuine
multi-line blocks.
-}
paragraphLine : Theme -> { size : Int, spacing : Int, width : Element.Length } -> Element msg
paragraphLine theme config =
    elLine theme { size = config.size + config.spacing, width = config.width }


{-| A non-interactive page-header placeholder. It delegates to
`Ui.Page.pageHeaderRaw` so the wrapped row, leading slot, title column spacing
and actions row match the loaded header exactly. Callers pass measured line
elements for the title and subtitle because the loaded header may use an el line
or a paragraph line.
-}
pageHeader :
    { leading : Maybe (Element msg)
    , title : Element msg
    , subtitle : List (Element msg)
    , actions : List (Element msg)
    }
    -> Element msg
pageHeader config =
    UiPage.pageHeaderRaw
        { leading = config.leading
        , title = config.title
        , subtitle = config.subtitle
        , actions = config.actions
        }


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


{-| A 44px checkbox row: a 28px circle, a 12px gap and a 16px title line.
Mirrors `Ui.Input.checkbox`, whose 44px minimum target and 28px icon keep the
form row height stable while preferences load.
-}
checkboxRow : Theme -> Element msg
checkboxRow theme =
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 44)
        , Element.spacing space12
        , skeletonRegion
        , testId "checkbox-row"
        ]
        [ Element.el
            [ Element.width (Element.px 28)
            , Element.height (Element.px 28)
            , Background.color theme.inputFill
            , Border.rounded radiusPill
            , uiClass "ui-skeleton"
            , Element.centerY
            ]
            Element.none
        , Element.el
            [ Element.width Element.fill
            , Element.centerY
            ]
            (elLine theme { size = 16, width = Element.fill })
        ]


{-| A 4x24 macro-dot placeholder. Mirrors `Surface.accentDotLabeled`, which
reserves the 12px leading slot with a 4x24 accent bar in list rows.
-}
dot : Theme -> Element msg
dot theme =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        , Background.color theme.inputFill
        , Border.rounded radiusHairline
        , uiClass "ui-skeleton"
        , skeletonRegion
        ]
        Element.none


{-| A 21px-tall status-badge placeholder. Mirrors `Chip.statusBadge` /
`Chip.coloredPill`, whose caption line plus 4px vertical padding is 21px high.
The 64px width is illustrative: the real pill width depends on the status label.
-}
badge : Theme -> Element msg
badge theme =
    Element.el
        [ Element.width (Element.px 64)
        , Element.height (Element.px 21)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , uiClass "ui-skeleton"
        , skeletonRegion
        ]
        Element.none


{-| A labelled text-control placeholder. `gap` is the measured space between
the 13px label line and the 44px control: text inputs use 7 (64px wrapper),
suffix inputs use 4 (61px wrapper). The inner control is inset horizontally to
match `Ui.Input`'s 10px padding plus 1px border; selects use `selectField` and
stay full width.
-}
field : Theme -> { labelWidth : Element.Length, gap : Int } -> Element msg
field theme config =
    fieldWithKind theme 13 config Nothing textControlInset


{-| A search-input placeholder. `UiInput.searchInput` uses a 16px body label
instead of the 13px caption used by ordinary fields, so the wrapper is 67px
(16 + 7 + 44), not 64px.
-}
searchField : Theme -> Element msg
searchField theme =
    fieldWithKind theme 16 { labelWidth = Element.px 80, gap = 7 } Nothing textControlInset


{-| A select/dropdown placeholder: label 13, 4px gap and a 44px trigger. The
explicit `data-field-kind="select"` marker lets the layout harness measure the
same control type instead of inferring it from spacing.
-}
selectField : Theme -> { labelWidth : Element.Length } -> Element msg
selectField theme config =
    fieldWithKind theme 13 { labelWidth = config.labelWidth, gap = 4 } (Just "select") 0


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
        [ control theme textControlInset ]


fieldWithKind :
    Theme
    -> Int
    -> { labelWidth : Element.Length, gap : Int }
    -> Maybe String
    -> Int
    -> Element msg
fieldWithKind theme labelHeight config kind controlInset =
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
            , Element.height (Element.px labelHeight)
            , Background.color theme.inputFill
            , Border.rounded radiusSmall
            , uiClass "ui-skeleton"
            ]
            Element.none
        , control theme controlInset
        ]


{-| The text-control inset: `Ui.Input` pads the input by 10px on each side and
adds a 1px border, so the border box is inset by 11px. Select triggers are not
inset; callers pass 0.
-}
textControlInset : Int
textControlInset =
    11


control : Theme -> Int -> Element msg
control theme inset =
    Element.el
        [ Element.width Element.fill
        , Element.paddingEach
            { top = 0, right = inset, bottom = 0, left = inset }
        ]
        (Element.el
            [ Element.width Element.fill
            , Element.height (Element.px 44)
            , Background.color theme.inputFill
            , Border.rounded radiusControl
            , uiClass "ui-skeleton"
            , testId "field-control"
            ]
            Element.none
        )


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


{-| A row of 22px category-chip placeholders. The loaded chips render through
`Element.html` (`.ui-chip-group` with a 4px gap), so this helper does too: the
parent `Surface.staticRow` text column then does not add its own 4px spacing
before the row. The 64px chip width is illustrative; the loaded width depends on
the category label.
-}
categoryChipRow : Theme -> { count : Int } -> Element msg
categoryChipRow theme config =
    Element.html
        (Html.div
            [ Html.Attributes.class "ui-chip-group" ]
            (List.repeat (max 0 config.count) (categoryChipHtml theme))
        )


categoryChipHtml : Theme -> Html msg
categoryChipHtml theme =
    Html.span
        [ Html.Attributes.class "ui-skeleton ui-skeleton-chip"
        , Html.Attributes.style "background-color" (toCssColor theme.inputFill)
        ]
        []


{-| Bottom action placeholders matching `Button.bottomActionButtons`: two
buttons share a row, any other non-zero count stacks in a column, and every
button is a full-width 48px pill. The order of the cases is intentional so the
skeleton keeps the loaded action row's geometry.
-}
bottomActions : Theme -> { count : Int } -> Element msg
bottomActions theme config =
    let
        buttonElements : List (Element msg)
        buttonElements =
            List.repeat (max 0 config.count)
                (buttonWithAttributes theme [ testId "bottom-action" ])
    in
    case buttonElements of
        [] ->
            Element.none

        [ onlyButton ] ->
            Element.column
                [ Element.width Element.fill, Element.spacing space12 ]
                [ onlyButton ]

        [ firstButton, secondButton ] ->
            Element.row
                [ Element.width Element.fill, Element.spacing space12 ]
                [ firstButton, secondButton ]

        _ ->
            Element.column
                [ Element.width Element.fill, Element.spacing space12 ]
                buttonElements


{-| A reserved overview stat tile. It mirrors `NutritionDetails.overviewItem`:
a min-130 tile with 12px padding, the tile fill and 2px spacing between the
caption, value and coverage lines. The third line is always reserved, so the
loaded tile has the same height whether coverage is complete (empty caption),
partial or absent. The line heights are the measured one-line paragraph boxes
(14px caption, 17px body).
-}
stat : Theme -> Element msg
stat theme =
    Element.column
        [ Element.width (Element.minimum 130 Element.fill)
        , Element.spacing space2
        , Element.padding space12
        , Background.color theme.inputFill
        , skeletonRegion
        , testId "stat"
        ]
        [ elLine theme { size = 14, width = Element.fill }
        , elLine theme { size = 17, width = Element.fill }
        , elLine theme { size = 14, width = Element.fill }
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


{-| A non-interactive list row placeholder. It delegates to
`Surface.staticRow` so the 16px row padding, 12px spacing, and leading/trailing
slots match `Surface.listRow` exactly. Callers provide skeleton content in each
slot because the required text height depends on the loaded row.
-}
row :
    { leading : List (Element msg)
    , title : Element msg
    , subtitle : List (Element msg)
    , trailing : List (Element msg)
    }
    -> Element msg
row config =
    Surface.staticRow
        { leading = config.leading
        , title = config.title
        , subtitle = config.subtitle
        , trailing = config.trailing
        }
