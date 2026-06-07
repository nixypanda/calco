module Ui exposing
    ( accentDot
    , accentPink
    , accentSoftGreen
    , accentSoftPink
    , accentYellow
    , badge
    , body
    , borderGray
    , brandBlue
    , brandBlueSoft
    , button
    , caption
    , carbsColor
    , card
    , cardActions
    , cardBg
    , cardShadow
    , chip
    , chipBackground
    , chipForeground
    , chips
    , coloredPill
    , dangerBg
    , dangerButton
    , dangerFg
    , dangerIconButton
    , dangerSolid
    , darkColor
    , defaultTruncationChars
    , detailRow
    , divider
    , dotSeparated
    , drawerSelectionBg
    , emptyState
    , errorBanner
    , fatColor
    , fieldLabel
    , formSection
    , ghostButton
    , hairline
    , iconButton
    , input
    , inputFill
    , isSmall
    , layout
    , linearProgress
    , listCard
    , listItemTitle
    , listRow
    , loading
    , macroBar
    , macroColor
    , macroDotGhost
    , maybeErrorBanner
    , mutedBody
    , mutedCaption
    , mutedColor
    , mutedParagraph
    , pageContainer
    , pageHeader
    , pageTitle
    , passwordInput
    , primarySubmitButton
    , primaryTeal
    , proteinColor
    , section
    , sectionTitle
    , selectDropdown
    , skeletonLoading
    , space12
    , space16
    , space2
    , space24
    , space4
    , space8
    , statBlock
    , statBlockGroup
    , statusGreen
    , statusRed
    , subsectionTitle
    , tableHeader
    , textMedium
    , truncateWithEllipsis
    , truncatedHeader
    , truncatedText
    , truncationCap
    )

import Data.Nutrition
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html
import Html.Attributes
import Html.Events
import Lib.ListExtra as ListExtra
import View.Charts



-- Accent palette


{-| Soft pink, used for protein and similar warm accents. Also the value
behind `proteinColor`.
-}
accentPink : Element.Color
accentPink =
    Element.rgb255 255 138 170


{-| Soft yellow accent, used for fat and warm schedule accents. Also the
value behind `fatColor`.
-}
accentYellow : Element.Color
accentYellow =
    Element.rgb255 255 210 80


{-| Soft pastel green for success states and the carbs bar fill.
-}
accentSoftGreen : Element.Color
accentSoftGreen =
    Element.rgb255 200 235 200


{-| Soft pastel pink for the "danger zone" backgrounds in the Admin
screens. Lighter than `dangerBg` so it can sit behind text.
-}
accentSoftPink : Element.Color
accentSoftPink =
    Element.rgb255 255 200 210


{-| The single primary blue. Used as the fill for primary buttons and the
foreground for secondary accents (links, ghost buttons, focus rings,
list-row leading stripes). White text reads cleanly on it.
-}
brandBlue : Element.Color
brandBlue =
    Element.rgb255 75 145 207


{-| Darker shade of `brandBlue` used for hover and pressed states.
-}
brandBluePressed : Element.Color
brandBluePressed =
    Element.rgb255 60 125 185


{-| Pale-blue tint, used as a hover background behind ghost / icon
buttons so secondary interactives have a visible affordance without
swapping foreground color.
-}
brandBlueSoft : Element.Color
brandBlueSoft =
    Element.rgb255 232 242 250


{-| Legacy mint. Being phased out — kept only so existing callers (chip
selected state, accent dots in Diary / Nutrients) still compile while
they migrate to `brandBlue`.
-}
primaryTeal : Element.Color
primaryTeal =
    Element.rgb255 94 224 213


{-| Subtle hairline color, used for rare separators. Matches `borderGray`
and `inputBorder` to keep the system aligned.
-}
divider : Element.Color
divider =
    Element.rgb255 232 234 238


{-| Light gray fill for inputs, dropdowns, chips, and icon buttons.
-}
inputFill : Element.Color
inputFill =
    Element.rgb255 244 246 248


{-| Primary text color, used for headings and body copy.
-}
textPrimary : Element.Color
textPrimary =
    Element.rgb255 28 32 44


{-| Muted secondary text.
-}
textMuted : Element.Color
textMuted =
    Element.rgb255 120 124 140


{-| Mid-weight text for subheadings.
-}
textMedium : Element.Color
textMedium =
    Element.rgb255 64 70 84


pageBg : Element.Color
pageBg =
    Element.rgb255 244 246 248


cardBg : Element.Color
cardBg =
    Element.rgb255 255 255 255


dangerBg : Element.Color
dangerBg =
    Element.rgb255 255 235 238


{-| Foreground color for destructive text/buttons in the Admin "danger
zone" headers.
-}
dangerFg : Element.Color
dangerFg =
    Element.rgb255 200 60 80


{-| Background color for the destructive button (see `dangerButton`).
-}
dangerSolid : Element.Color
dangerSolid =
    Element.rgb255 255 107 122


{-| Foreground color for the "active" status pill in the Admin views.
Paired with `accentSoftGreen` as the background.
-}
statusGreen : Element.Color
statusGreen =
    Element.rgb255 50 110 60


{-| Foreground color for the "disabled" status pill in the Admin views.
Paired with `accentSoftPink` as the background.
-}
statusRed : Element.Color
statusRed =
    Element.rgb255 180 60 80


{-| Blue-tinted selected-state background for navigation items in the side
drawer.
-}
drawerSelectionBg : Element.Color
drawerSelectionBg =
    Element.rgb255 232 242 250


{-| Backwards-compatible alias for the pink protein accent.
-}
proteinColor : Element.Color
proteinColor =
    accentPink


{-| Backwards-compatible: soft green for carbs.
-}
carbsColor : Element.Color
carbsColor =
    accentSoftGreen


{-| Backwards-compatible: yellow for fat.
-}
fatColor : Element.Color
fatColor =
    accentYellow


borderGray : Element.Color
borderGray =
    divider


mutedColor : Element.Color
mutedColor =
    textMuted


darkColor : Element.Color
darkColor =
    textPrimary



-- Spacing scale
--
-- A 4px-based scale used for `Element.spacing`, `Element.padding`, and
-- `Element.paddingXY`. Stick to these values when adding new layout — only
-- reach for raw literals if the layout genuinely needs an off-scale value
-- (e.g., aligning to a 1px hairline or a known control height).


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



-- Typography
--
-- Semantic helpers are the primary API: pageTitle/sectionTitle/subsectionTitle
-- for headings, bodyText/mutedBody/mutedParagraph for body copy, captionText/
-- mutedCaption for small labels. Each bundles size + weight + color so callers
-- don't wire Font.bold and Font.color by hand.
--
-- The bare size attributes `body` and `caption` remain exported as primitives
-- for places (table cells, form labels, button labels) that need to compose
-- size with other attributes on a non-`Element.el` host (e.g. Input.button).
--
-- Scale: 28 / 22 / 17 / 14 / 12.


body : Element.Attribute msg
body =
    Font.size 14


caption : Element.Attribute msg
caption =
    Font.size 12


sizePageTitle : Element.Attribute msg
sizePageTitle =
    Font.size 28


sizeSectionTitle : Element.Attribute msg
sizeSectionTitle =
    Font.size 22


sizeSubsectionTitle : Element.Attribute msg
sizeSubsectionTitle =
    Font.size 17


pageTitle : String -> Element msg
pageTitle text =
    Element.el
        [ sizePageTitle
        , Font.bold
        , Font.color textPrimary
        , Region.heading 1
        ]
        (Element.text text)


sectionTitle : String -> Element msg
sectionTitle text =
    Element.el
        [ sizeSectionTitle
        , Font.bold
        , Font.color textPrimary
        , Region.heading 2
        ]
        (Element.text text)


subsectionTitle : String -> Element msg
subsectionTitle text =
    Element.el
        [ sizeSubsectionTitle
        , Font.bold
        , Font.color textPrimary
        , Region.heading 3
        ]
        (Element.text text)


listItemTitle : String -> Element msg
listItemTitle text =
    Element.el
        [ body
        , Font.bold
        , Font.color textPrimary
        ]
        (Element.text text)


mutedCaption : String -> Element msg
mutedCaption text =
    Element.el
        [ caption
        , Font.color textMuted
        ]
        (Element.text text)


tableHeader : String -> Element msg
tableHeader text =
    Element.el
        [ body
        , Font.bold
        , Font.color textMuted
        ]
        (Element.text text)



-- Surfaces & layout


{-| Soft drop shadow applied to cards and overlays.
-}
cardShadow : Element.Attribute msg
cardShadow =
    Element.htmlAttribute
        (Html.Attributes.style "box-shadow" "0 4px 16px rgba(28, 32, 44, 0.06)")


layout : Element msg -> Element msg
layout content =
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color pageBg
        , Font.family [ Font.typeface "Inter", Font.sansSerif ]
        , Font.color textPrimary
        , body
        ]
        [ content ]


pageContainer : Element.Device -> List (Element msg) -> Element msg
pageContainer device children =
    let
        horizontalPadding : Int
        horizontalPadding =
            if isSmall device then
                16

            else
                24
    in
    Element.column
        [ Element.centerX
        , Element.width (Element.fill |> Element.maximum 960)
        , Element.spacing space16
        , Element.paddingEach
            { top = horizontalPadding
            , right = horizontalPadding
            , bottom = horizontalPadding
            , left = horizontalPadding
            }
        ]
        children


{-| True when the device is classified as a phone by `Element.classifyDevice`
(elm-ui's `shortSide < 600` rule). Use this as the single small-screen gate
across the app so call sites stay readable. `Tablet`, `Desktop`, and
`BigDesktop` all return `False`.
-}
isSmall : Element.Device -> Bool
isSmall device =
    device.class == Element.Phone


{-| Default cap used by `truncatedText` when the caller doesn't supply one.
40 chars matches the long-name truncation sites in the diary, meal, and food
list views.
-}
defaultTruncationChars : Int
defaultTruncationChars =
    40


{-| Single-line character cap used by `truncateWithEllipsis` call sites that
should be tighter on phones. Defaults to `defaultTruncationChars` (40) on
non-Phone devices; Phone gets 25 to keep long names from blowing past narrow
viewports.
-}
truncationCap : Element.Device -> Int
truncationCap device =
    if isSmall device then
        25

    else
        defaultTruncationChars


{-| Truncate a string to at most `maxChars` code points and append a single
ellipsis character. Pairs with `Ui.truncatedText` for the rendered form. Pure
Elm, no CSS, safe to use inside a flex row. The cap counts the ellipsis: a
`maxChars` of 4 always returns a 4-character string.

    Ui.truncateWithEllipsis 12 "Roasted Sweet Potato" --> "Roasted Swe..."

-}
truncateWithEllipsis : Int -> String -> String
truncateWithEllipsis maxChars string =
    let
        visible : Int
        visible =
            Basics.max 0 (maxChars - 3)
    in
    if String.length string <= maxChars then
        string

    else
        String.left visible string ++ "..."


{-| Render `string` as a single-line text element that fills its parent,
clips overflow, and truncates to the device-aware cap. Use this for long
product / meal / log names that would otherwise push the row wider than a
phone viewport.

    Ui.truncatedText device "Roasted Sweet Potato"

-}
truncatedText : Element.Device -> String -> Element msg
truncatedText device string =
    Element.el
        [ Element.width Element.fill
        , Element.clip
        ]
        (Element.text (truncateWithEllipsis (truncationCap device) string))


card : List (Element msg) -> Element msg
card children =
    Element.column
        [ Element.width Element.fill
        , Background.color cardBg
        , Border.rounded 20
        , cardShadow
        , Element.padding space20
        , Element.spacing space12
        ]
        children


{-| Canonical page-level header: optional leading element (e.g. macroDot),
bold title (truncated for narrow viewports), optional muted subtitle below,
and a right-aligned row of actions (typically `iconButton` / `dangerIconButton`).
Renders as a bare row — no card wrapper — so the page's main content can
flow directly beneath it.
-}
pageHeader :
    Element.Device
    ->
        { leading : Maybe (Element msg)
        , title : String
        , subtitle : Maybe String
        , actions : List (Element msg)
        }
    -> Element msg
pageHeader device config =
    let
        leadingElement : Element msg
        leadingElement =
            case config.leading of
                Just el ->
                    el

                Nothing ->
                    Element.none

        titleColumn : Element msg
        titleColumn =
            Element.column
                [ Element.width Element.fill, Element.spacing space4 ]
                (truncatedPageTitle device config.title
                    :: (case config.subtitle of
                            Just text ->
                                [ mutedBody text ]

                            Nothing ->
                                []
                       )
                )

        actionsRow : Element msg
        actionsRow =
            if List.isEmpty config.actions then
                Element.none

            else
                Element.row [ Element.spacing space8 ] config.actions
    in
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.spacing space12
        ]
        [ leadingElement, titleColumn, actionsRow ]


{-| A 4×24 transparent spacer matching the dimensions of `accentDot` /
`View.Nutrients.macroDot`. Use as the leading element of a row that sits
beneath a header which has a colored dot, so content aligns with where
the header's title text begins.
-}
macroDotGhost : Element msg
macroDotGhost =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        ]
        Element.none


cardActions : List (Element msg) -> Element msg
cardActions buttons =
    Element.row
        [ Element.width Element.fill
        , Element.paddingEach { top = 12, right = 0, bottom = 0, left = 0 }
        , Element.spacing space12
        ]
        buttons


{-| Canonical sectioned card. When `header` is present, a `hairline` sits
between it and the `body`; when `footer` is present, a `hairline` sits
between the `body` and the footer. Use this whenever a card carries a
header, a footer, or both — it enforces the project-wide hairline rule
in one place.
-}
section :
    { header : Maybe (Element msg)
    , body : List (Element msg)
    , footer : Maybe (Element msg)
    }
    -> Element msg
section config =
    let
        headerSlot : List (Element msg)
        headerSlot =
            case config.header of
                Just el ->
                    [ el, hairline ]

                Nothing ->
                    []

        footerSlot : List (Element msg)
        footerSlot =
            case config.footer of
                Just el ->
                    [ hairline, el ]

                Nothing ->
                    []
    in
    card (headerSlot ++ config.body ++ footerSlot)


{-| A card whose body is a title, a hairline, and then its content. Used for
form sections in `Page.CustomFood.Form` so every section reads the same way.
Convenience wrapper around `section` with only a string header.
-}
formSection : String -> List (Element msg) -> Element msg
formSection title content =
    section
        { header = Just (subsectionTitle title)
        , body = content
        , footer = Nothing
        }


{-| A card containing a vertical list of rows with a "+ Create X" ghost
button pinned to the bottom. The create button is shown even when the row
list is empty, which is the canonical empty state for the index pages.
-}
listCard : { rows : List (Element msg), createButton : Element msg } -> Element msg
listCard config =
    section
        { header = Nothing
        , body =
            if List.isEmpty config.rows then
                [ emptyListBody ]

            else
                config.rows
        , footer = Just config.createButton
        }


emptyListBody : Element msg
emptyListBody =
    Element.el
        [ Element.width Element.fill
        , Element.padding space16
        ]
        (mutedParagraph "No items yet.")


{-| A clickable list row with an optional leading element (macro dot,
icon), a title + subtitle column in the middle, and optional trailing
elements (action icons, badges). Clicking the title area fires `onSelect`;
trailing items keep their own click handlers so destructive actions stay
out of the row's primary tap target.
-}
listRow :
    { onSelect : msg
    , leading : List (Element msg)
    , title : Element msg
    , subtitle : List (Element msg)
    , trailing : List (Element msg)
    }
    -> Element msg
listRow config =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.padding space16
        , Element.spacing space12
        ]
        [ Input.button
            [ Element.width Element.fill ]
            { onPress = Just config.onSelect
            , label =
                Element.row [ Element.width Element.fill, Element.spacing space12 ]
                    [ listRowLeading config.leading
                    , Element.column
                        [ Element.width Element.fill
                        , Element.spacing space4
                        , Element.alignTop
                        ]
                        (config.title :: config.subtitle)
                    ]
            }
        , if List.isEmpty config.trailing then
            Element.none

          else
            Element.row
                [ Element.padding space8
                , Element.spacing space12
                , Element.alignTop
                ]
                config.trailing
        ]


listRowLeading : List (Element msg) -> Element msg
listRowLeading leading =
    Element.el
        [ Element.width (Element.px 12)
        , Element.paddingEach { top = 2, right = 0, bottom = 0, left = 0 }
        , Element.alignTop
        ]
        (case leading of
            first :: _ ->
                first

            [] ->
                Element.none
        )



-- States


loading : String -> Element msg
loading message =
    Element.el
        [ Font.color textMuted ]
        (Element.text message)


emptyState : String -> Element msg
emptyState message =
    card
        [ Element.paragraph
            [ Font.color textMuted
            , Font.center
            , Element.padding space8
            ]
            [ Element.text message ]
        ]


maybeErrorBanner : Maybe String -> Element msg
maybeErrorBanner maybeError =
    Maybe.withDefault Element.none (Maybe.map errorBanner maybeError)


errorBanner : String -> Element msg
errorBanner message =
    Element.el
        [ Background.color dangerBg
        , Font.color dangerFg
        , Border.rounded 12
        , Element.padding space12
        , Element.width Element.fill
        ]
        (Element.text message)



-- Buttons


button : String -> msg -> Element msg
button label msg =
    Input.button
        [ Background.color brandBlue
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 999
        , Element.paddingEach { top = 12, right = 18, bottom = 12, left = 18 }
        , Font.medium
        , Element.mouseOver [ Background.color brandBluePressed ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


{-| Full-width primary CTA, intended for use inside `cardActions` as a
page's main submit/save button. Same fill as `button`, but `width fill`
and slightly larger padding so it reads as the primary affordance.
-}
primaryButton : String -> msg -> Element msg
primaryButton label msg =
    Input.button
        [ Background.color brandBlue
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 999
        , Element.width Element.fill
        , Element.paddingEach { top = 14, right = 20, bottom = 14, left = 20 }
        , Font.medium
        , Font.center
        , Element.mouseOver [ Background.color brandBluePressed ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


{-| Full-width variant of `submitButton`. Use for a page's primary CTA when
the button stands alone (no destructive icon paired beside it).
-}
primarySubmitButton : Bool -> String -> String -> msg -> Element msg
primarySubmitButton isSubmitting idleLabel submittingLabel msg =
    primaryButton
        (if isSubmitting then
            submittingLabel

         else
            idleLabel
        )
        msg


dangerButton : String -> msg -> Element msg
dangerButton label msg =
    Input.button
        [ Background.color dangerSolid
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 999
        , Element.paddingEach { top = 12, right = 18, bottom = 12, left = 18 }
        , Font.medium
        , Element.mouseOver [ Background.color dangerFg ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


{-| Transparent pill with brand-blue text. Used for "+ Add" affordances
where the pill shape still applies but the action is secondary.
-}
ghostButton : String -> msg -> Element msg
ghostButton label msg =
    Input.button
        [ Border.rounded 999
        , Element.paddingEach { top = 8, right = 14, bottom = 8, left = 14 }
        , Font.color brandBlue
        , Font.medium
        , Element.mouseOver [ Background.color brandBlueSoft ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }



-- Inputs


input : String -> String -> (String -> msg) -> Element msg
input label value onChange =
    Input.text
        [ Border.rounded 12
        , Background.color inputFill
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [] (fieldLabel label)
        }


passwordInput : String -> String -> (String -> msg) -> Element msg
passwordInput label value onChange =
    Input.currentPassword
        [ Border.rounded 12
        , Background.color inputFill
        , Element.padding 10
        ]
        { onChange = onChange
        , text = value
        , placeholder = Nothing
        , label = Input.labelAbove [] (fieldLabel label)
        , show = False
        }


{-| Caption-sized, semibold label used above inputs, dropdowns, and other
form controls. Visually reads as a small section header.
-}
fieldLabel : String -> Element msg
fieldLabel label_ =
    Element.el
        [ caption
        , Font.medium
        , Font.color textPrimary
        ]
        (Element.text label_)



-- Display


mutedBody : String -> Element msg
mutedBody text =
    Element.el
        [ Font.color textMuted
        , body
        ]
        (Element.text text)


mutedParagraph : String -> Element msg
mutedParagraph text =
    Element.paragraph
        [ Font.color textMuted
        , body
        ]
        [ Element.text text ]


detailRow : String -> Element msg -> Element msg
detailRow label_ value =
    Element.row [ Element.spacing space4 ]
        [ Element.el [ Font.color textMedium, caption ]
            (Element.text (label_ ++ ":"))
        , value
        ]


badge : String -> Element msg
badge label_ =
    Element.el
        [ Background.color inputFill
        , Font.color textPrimary
        , Border.rounded 999
        , Element.paddingEach { top = 4, right = 8, bottom = 4, left = 8 }
        , caption
        , Font.medium
        ]
        (Element.text label_)


selectDropdown :
    { label : String
    , selected : a
    , options : List ( a, String )
    , onChange : a -> msg
    , isOpen : Bool
    , onToggle : msg
    }
    -> Element msg
selectDropdown config =
    let
        selectedLabel : String
        selectedLabel =
            case List.filter (\( val, _ ) -> val == config.selected) config.options of
                ( _, lbl ) :: _ ->
                    lbl

                [] ->
                    ""

        isSelected : a -> Bool
        isSelected val =
            val == config.selected

        renderOption : ( a, String ) -> Element msg
        renderOption ( val, lbl ) =
            Input.button
                [ Element.width Element.fill
                , Element.paddingXY 14 10
                , Background.color
                    (if isSelected val then
                        brandBlue

                     else
                        cardBg
                    )
                , Font.color
                    (if isSelected val then
                        Element.rgb255 255 255 255

                     else
                        textPrimary
                    )
                ]
                { onPress = Just (config.onChange val)
                , label = Element.text lbl
                }

        optionsElement : Element msg
        optionsElement =
            Element.column
                [ Element.width Element.fill
                , Border.rounded 12
                , Background.color cardBg
                , cardShadow
                , Element.moveDown 4
                ]
                (List.map renderOption config.options)

        triggerAnchor : List (Element.Attribute msg)
        triggerAnchor =
            if config.isOpen then
                [ Element.width Element.fill, Element.below optionsElement ]

            else
                [ Element.width Element.fill ]
    in
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        [ fieldLabel config.label
        , Element.el triggerAnchor
            (Input.button
                [ Element.width Element.fill
                , Border.rounded 12
                , Background.color inputFill
                , Element.padding 10
                , Border.width 1
                , Border.color inputFill
                , Element.mouseOver [ Border.color brandBlue ]
                ]
                { onPress = Just config.onToggle
                , label =
                    Element.row [ Element.width Element.fill, Element.spacing space8 ]
                        [ Element.el
                            [ Element.width Element.fill
                            , body
                            , Font.color
                                (if selectedLabel == "" then
                                    textMuted

                                 else
                                    textPrimary
                                )
                            ]
                            (Element.text
                                (if selectedLabel == "" then
                                    "Select…"

                                 else
                                    selectedLabel
                                )
                            )
                        , Element.text
                            (if config.isOpen then
                                "▲"

                             else
                                "▼"
                            )
                        ]
                }
            )
        ]


macroColor : Data.Nutrition.Macro -> Element.Color
macroColor m =
    case m of
        Data.Nutrition.Protein ->
            proteinColor

        Data.Nutrition.Carbs ->
            carbsColor

        Data.Nutrition.Fat ->
            fatColor


macroBar :
    { label : String
    , value : Float
    , unit : String
    , color : Element.Color
    , max : Float
    }
    -> Element msg
macroBar config =
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
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        [ Element.row [ Element.width Element.fill ]
            [ Element.el [ Font.bold, body, Font.color textPrimary ] (Element.text config.label)
            , Element.el
                [ body
                , Font.color textMuted
                , Element.alignRight
                ]
                (Element.text (String.fromInt (round config.value) ++ " " ++ config.unit))
            ]
        , Element.row
            [ Element.width Element.fill
            , Element.height (Element.px 10)
            , Background.color inputFill
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
        ]


skeletonLoading : Element msg
skeletonLoading =
    Element.column [ Element.width Element.fill, Element.spacing space12 ]
        [ skeletonBar
        , skeletonBar
        , skeletonBar
        ]


skeletonBar : Element msg
skeletonBar =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 16)
        , Background.color inputFill
        , Border.rounded 8
        ]
        Element.none



-- New components (see docs/visual-reskin.md §6)


truncatedHeader : Device -> String -> Element msg
truncatedHeader device heading =
    Element.el
        [ sizeSectionTitle
        , Font.bold
        , Font.color textPrimary
        , Region.heading 2
        , Element.width Element.fill
        , Element.clip
        , Element.height (Element.px 28)
        ]
        (Element.text (truncateWithEllipsis (truncationCap device) heading))


truncatedPageTitle : Device -> String -> Element msg
truncatedPageTitle device heading =
    Element.el
        [ sizePageTitle
        , Font.bold
        , Font.color textPrimary
        , Region.heading 1
        , Element.width Element.fill
        , Element.clip
        , Element.height (Element.px 34)
        ]
        (Element.text (truncateWithEllipsis (truncationCap device) heading))


{-| 40×40 circular icon button. The label is rendered as text glyphs
(←, ☰, ✕, +, etc.). `title` is forwarded as both a tooltip and a
semantic label for screen readers. Empty `label` is allowed and
renders an invisible clickable circle, useful as a no-op leading
placeholder.

Background is `cardBg` (white) with a 1px `divider` border so the
button has a defined edge whether it sits on the page background
(`pageBg`) or inside a white card.

-}
iconButton : { label : String, title : String, onPress : msg } -> Element msg
iconButton config =
    Input.button
        [ Element.width (Element.px 40)
        , Element.height (Element.px 40)
        , Background.color cardBg
        , Font.color textPrimary
        , Font.center
        , Border.rounded 999
        , Border.width 1
        , Border.color divider
        , Element.mouseOver
            [ Background.color brandBlueSoft
            , Border.color brandBlue
            ]
        , Element.htmlAttribute (Html.Attributes.title config.title)
        ]
        { onPress = Just config.onPress
        , label = Element.text config.label
        }


{-| 40×40 circular icon button styled for destructive actions. Outlined
at rest (transparent fill, danger-red icon and 1px border) so a row of
list items doesn't shout. Flips to a solid danger fill on hover/focus
when the action is about to be triggered. `title` doubles as the tooltip
and the semantic label for screen readers.
-}
dangerIconButton : { label : String, title : String, onPress : msg } -> Element msg
dangerIconButton config =
    Input.button
        [ Element.width (Element.px 40)
        , Element.height (Element.px 40)
        , Background.color cardBg
        , Font.color dangerFg
        , Font.center
        , Border.rounded 999
        , Border.width 1
        , Border.color dangerFg
        , Element.mouseOver
            [ Background.color dangerSolid
            , Font.color (Element.rgb255 255 255 255)
            , Border.color dangerSolid
            ]
        , Element.htmlAttribute (Html.Attributes.title config.title)
        ]
        { onPress = Just config.onPress
        , label = Element.text config.label
        }


{-| Background color used by `chip` for the selected vs. unselected state.
Exposed so tests can assert the binding.
-}
chipBackground : Bool -> Element.Color
chipBackground selected =
    if selected then
        primaryTeal

    else
        inputFill


{-| Foreground color used by `chip` for the selected vs. unselected state.
-}
chipForeground : Bool -> Element.Color
chipForeground selected =
    if selected then
        Element.rgb255 255 255 255

    else
        textPrimary


{-| Pill-shaped selector chip, 32px tall. Pass `Nothing` for `onClick` to
render a non-interactive pill (use this for visual-only badges shaped
like a chip).
-}
chip :
    { label : String
    , selected : Bool
    , onClick : Maybe msg
    }
    -> Element msg
chip config =
    Element.html (chipHtml config)


toCssColor : Element.Color -> String
toCssColor color =
    let
        { red, green, blue, alpha } =
            Element.toRgb color
    in
    "rgba("
        ++ String.fromInt (round (red * 255))
        ++ ", "
        ++ String.fromInt (round (green * 255))
        ++ ", "
        ++ String.fromInt (round (blue * 255))
        ++ ", "
        ++ String.fromFloat alpha
        ++ ")"


{-| The centerY stuff with elm-ui is not working in this case. So, resorting to this shit
-}
chipHtml :
    { label : String
    , selected : Bool
    , onClick : Maybe msg
    }
    -> Html.Html msg
chipHtml config =
    let
        baseStyles : List (Html.Attribute msg)
        baseStyles =
            [ Html.Attributes.style "display" "inline-flex"
            , Html.Attributes.style "align-items" "center"
            , Html.Attributes.style "justify-content" "center"
            , Html.Attributes.style "height" "22px"
            , Html.Attributes.style "padding" "0 12px"
            , Html.Attributes.style "border-radius" "999px"
            , Html.Attributes.style "background-color" (toCssColor (chipBackground config.selected))
            , Html.Attributes.style "color" (toCssColor (chipForeground config.selected))
            , Html.Attributes.style "font-size" "13px"
            , Html.Attributes.style "font-family" "inherit"
            , Html.Attributes.style "line-height" "1"
            , Html.Attributes.style "white-space" "nowrap"
            ]
    in
    case config.onClick of
        Just msg ->
            Html.button
                (List.append baseStyles
                    [ Html.Attributes.style "border" "none"
                    , Html.Attributes.style "cursor" "pointer"
                    , Html.Events.onClick msg
                    ]
                )
                [ Html.text config.label ]

        Nothing ->
            Html.span
                baseStyles
                [ Html.text config.label ]


chips : List String -> Element msg
chips strings =
    if List.isEmpty strings then
        Element.none

    else
        Element.html
            (Html.div
                [ Html.Attributes.style "display" "flex"
                , Html.Attributes.style "flex-wrap" "wrap"
                , Html.Attributes.style "gap" "4px"
                , Html.Attributes.style "width" "100%"
                ]
                (List.map
                    (\c ->
                        chipHtml { label = c, selected = False, onClick = Nothing }
                    )
                    strings
                )
            )


{-| 24px-tall pastel pill, useful for status indicators.
-}
coloredPill :
    { label : String
    , bg : Element.Color
    , fg : Element.Color
    }
    -> Element msg
coloredPill config =
    Element.el
        [ Background.color config.bg
        , Font.color config.fg
        , Border.rounded 999
        , Element.paddingEach { top = 4, right = 10, bottom = 4, left = 10 }
        , caption
        , Font.medium
        ]
        (Element.text config.label)


{-| A solid-color stat block. 100px tall, ~120px wide, radius 24.
Inside: big white value, white unit caption, white label caption.
-}
statBlock :
    { value : String
    , unit : String
    , label : String
    , color : Element.Color
    }
    -> Element msg
statBlock config =
    Element.column
        [ Element.width (Element.fill |> Element.maximum 120)
        , Element.height (Element.px 100)
        , Background.color config.color
        , Border.rounded 24
        , Element.paddingEach { top = 12, right = 12, bottom = 12, left = 12 }
        , Element.spacing space2
        ]
        [ Element.el
            [ sizePageTitle
            , Font.bold
            , Font.color (Element.rgb255 255 255 255)
            ]
            (Element.text config.value)
        , Element.el
            [ caption
            , Font.color (Element.rgb255 255 255 255)
            ]
            (Element.text config.unit)
        , Element.el
            [ caption
            , Font.color (Element.rgb255 255 255 255)
            ]
            (Element.text config.label)
        ]


{-| Four stat blocks in a 2×2 grid with 12px spacing.
-}
statBlockGroup : List (Element msg) -> Element msg
statBlockGroup blocks =
    let
        pairs : List ( Element msg, Element msg )
        pairs =
            ListExtra.groupsOf 2 blocks

        row : ( Element msg, Element msg ) -> Element msg
        row ( a, b ) =
            Element.row [ Element.spacing space12 ]
                [ a
                , b
                ]
    in
    Element.column [ Element.spacing space12 ]
        (List.map row pairs)


linearProgress :
    { value : Float
    , max : Float
    , color : Element.Color
    }
    -> Element msg
linearProgress config =
    View.Charts.linearProgress
        { value = config.value
        , max = config.max
        , color = config.color
        , trackColor = inputFill
        }


{-| 4px × 24px rounded vertical bar used as a leading element on list
rows (foods, meals, users) in place of image placeholders.
-}
accentDot : Element.Color -> Element msg
accentDot color =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        , Background.color color
        , Border.rounded 2
        ]
        Element.none


{-| A 1px-tall horizontal hairline using the muted `divider` color. Used
to separate regions within a card (e.g., the diary slot card's
header / log rows / add-food sections) without adding visual weight.
-}
hairline : Element msg
hairline =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 1)
        , Background.color divider
        ]
        Element.none


dotSeparated : List (Maybe String) -> String
dotSeparated strings =
    strings |> List.filterMap identity |> String.join " ⋅ "
