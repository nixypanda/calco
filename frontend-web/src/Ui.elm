module Ui exposing
    ( accentDot
    , accentLavender
    , accentLightBlue
    , accentPink
    , accentSoftGreen
    , accentSoftPink
    , accentYellow
    , badge
    , body
    , borderGray
    , button
    , caption
    , carbsColor
    , card
    , cardActions
    , cardBg
    , cardShadow
    , chip
    , chipBackground
    , coloredPill
    , dangerBg
    , dangerButton
    , dangerFg
    , darkColor
    , detailRow
    , display
    , emptyState
    , errorBanner
    , fatColor
    , ghostButton
    , hairline
    , heading1
    , heading2
    , heading3
    , iconButton
    , input
    , inputFill
    , layout
    , linearProgress
    , loading
    , macroBar
    , mutedColor
    , mutedText
    , pageContainer
    , passwordInput
    , primaryTeal
    , proteinColor
    , sectionHeader
    , select
    , selectDropdown
    , skeletonLoading
    , statBlock
    , statBlockGroup
    , submitButton
    , textMedium
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
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


{-| Soft lavender, used for selected drawer items, dinner meal slots,
and sweet/dessert categories.
-}
accentLavender : Element.Color
accentLavender =
    Element.rgb255 186 170 255


{-| Light blue, used as a category fallback and for the "Other" meal slot.
-}
accentLightBlue : Element.Color
accentLightBlue =
    Element.rgb255 150 200 255


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


{-| Mint primary. The pressed state is exposed as `primaryTealPressed` for
callers that can wire hover/press attributes.
-}
primaryTeal : Element.Color
primaryTeal =
    Element.rgb255 94 224 213


primaryTealPressed : Element.Color
primaryTealPressed =
    Element.rgb255 70 200 190


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



-- Typography


display : Element.Attribute msg
display =
    Font.size 32


heading1 : Element.Attribute msg
heading1 =
    Font.size 22


heading2 : Element.Attribute msg
heading2 =
    Font.size 20


heading3 : Element.Attribute msg
heading3 =
    Font.size 18


body : Element.Attribute msg
body =
    Font.size 14


caption : Element.Attribute msg
caption =
    Font.size 13


small : Element.Attribute msg
small =
    Font.size 12


bold : Element.Attribute msg
bold =
    Font.bold


medium : Element.Attribute msg
medium =
    Font.medium



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


pageContainer : List (Element msg) -> Element msg
pageContainer children =
    Element.column
        [ Element.centerX
        , Element.width (Element.fill |> Element.maximum 960)
        , Element.spacing 16
        , Element.paddingEach { top = 24, right = 24, bottom = 24, left = 24 }
        ]
        children


card : List (Element msg) -> Element msg
card children =
    Element.column
        [ Element.width Element.fill
        , Background.color cardBg
        , Border.rounded 20
        , cardShadow
        , Element.padding 20
        , Element.spacing 12
        ]
        children


sectionHeader : String -> Element msg
sectionHeader title =
    Element.el
        [ heading3
        , bold
        , Font.letterSpacing 0.5
        , Element.paddingEach { top = 0, right = 0, bottom = 0, left = 0 }
        ]
        (Element.text (String.toUpper title))


cardActions : List (Element msg) -> Element msg
cardActions buttons =
    Element.row
        [ Element.width Element.fill
        , Element.paddingEach { top = 12, right = 0, bottom = 0, left = 0 }
        , Element.spacing 12
        ]
        buttons



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
            , Element.padding 8
            ]
            [ Element.text message ]
        ]


errorBanner : String -> Element msg
errorBanner message =
    Element.el
        [ Background.color dangerBg
        , Font.color dangerFg
        , Border.rounded 12
        , Element.padding 12
        , Element.width Element.fill
        ]
        (Element.text message)



-- Buttons


button : String -> msg -> Element msg
button label msg =
    Input.button
        [ Background.color primaryTeal
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded 999
        , Element.paddingEach { top = 12, right = 18, bottom = 12, left = 18 }
        , Font.medium
        ]
        { onPress = Just msg
        , label = Element.text label
        }


submitButton : Bool -> String -> String -> msg -> Element msg
submitButton isSubmitting idleLabel submittingLabel msg =
    button
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
        ]
        { onPress = Just msg
        , label = Element.text label
        }


{-| Transparent pill with teal text. Used for "+ Add" affordances where
the pill shape still applies but the action is secondary.
-}
ghostButton : String -> msg -> Element msg
ghostButton label msg =
    Input.button
        [ Border.rounded 999
        , Element.paddingEach { top = 8, right = 14, bottom = 8, left = 14 }
        , Font.color primaryTeal
        , Font.medium
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
        , label = Input.labelAbove [ body, medium, Font.color textPrimary ] (Element.text label)
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
        , label = Input.labelAbove [ body, medium, Font.color textPrimary ] (Element.text label)
        , show = False
        }


select :
    String
    -> a
    -> List ( a, String )
    -> (a -> msg)
    -> Element msg
select label_ selected options onChange =
    Input.radio [ Element.spacing 8 ]
        { onChange = onChange
        , selected = Just selected
        , label = Input.labelAbove [ body, medium, Font.color textPrimary ] (Element.text label_)
        , options = List.map (\( val, lbl ) -> Input.option val (Element.text lbl)) options
        }



-- Display


mutedText : String -> Element msg
mutedText text =
    Element.el
        [ Font.color textMuted
        , body
        ]
        (Element.text text)


detailRow : String -> Element msg -> Element msg
detailRow label_ value =
    Element.row [ Element.spacing 4 ]
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
        , small
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

        optionsElement : Element msg
        optionsElement =
            if config.isOpen then
                Element.column
                    [ Element.width Element.fill
                    , Element.spacing 0
                    , Border.rounded 12
                    , Background.color cardBg
                    , cardShadow
                    ]
                    (List.map
                        (\( val, lbl ) ->
                            Input.button
                                [ Element.width Element.fill
                                , Element.paddingEach
                                    { top = 10, bottom = 10, left = 14, right = 14 }
                                , body
                                , Background.color
                                    (if val == config.selected then
                                        primaryTealPressed

                                     else
                                        cardBg
                                    )
                                , Font.color
                                    (if val == config.selected then
                                        Element.rgb255 255 255 255

                                     else
                                        textPrimary
                                    )
                                ]
                                { onPress = Just (config.onChange val)
                                , label = Element.text lbl
                                }
                        )
                        config.options
                    )

            else
                Element.none
    in
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Element.el [ body, Font.medium, Font.color textPrimary ] (Element.text config.label)
        , Input.button
            (List.concat
                [ [ Element.width Element.fill
                  , Border.rounded 12
                  , Background.color inputFill
                  , Element.padding 10
                  ]
                , if config.isOpen then
                    [ Element.below optionsElement ]

                  else
                    []
                ]
            )
            { onPress = Just config.onToggle
            , label =
                Element.row [ Element.width Element.fill, Element.spacing 8 ]
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
        ]


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
    Element.column [ Element.width Element.fill, Element.spacing 4 ]
        [ Element.row [ Element.width Element.fill ]
            [ Element.el [ bold, body, Font.color textPrimary ] (Element.text config.label)
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
    Element.column [ Element.width Element.fill, Element.spacing 12 ]
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


{-| 40×40 circular icon button. The label is rendered as text glyphs
(←, ☰, ✕, +, etc.). Empty string is allowed and renders an invisible
clickable circle, useful as a no-op leading placeholder.
-}
iconButton : String -> msg -> Element msg
iconButton label msg =
    Input.button
        [ Element.width (Element.px 40)
        , Element.height (Element.px 40)
        , Background.color inputFill
        , Font.color textPrimary
        , Font.center
        , Border.rounded 999
        ]
        { onPress = Just msg
        , label = Element.text label
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
            , Html.Attributes.style "height" "32px"
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
        , Element.spacing 2
        ]
        [ Element.el
            [ Font.size 32
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
            Element.row [ Element.spacing 12 ]
                [ a
                , b
                ]
    in
    Element.column [ Element.spacing 12 ]
        (List.map row pairs)


linearProgress :
    { value : Float
    , max : Float
    , color : Element.Color
    }
    -> Element msg
linearProgress config =
    View.Charts.linearProgress config


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
