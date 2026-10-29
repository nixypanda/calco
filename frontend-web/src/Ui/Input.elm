module Ui.Input exposing
    ( InputConfig
    , SearchLabel(..)
    , checkbox
    , completionDropdown
    , completionRow
    , decimalInputWithSuffix
    , disabledInput
    , fieldLabel
    , input
    , numericInput
    , numericInputMode
    , optionRow
    , optionRowWithState
    , passwordInput
    , searchInput
    , selectDropdown
    , selectDropdownWithState
    , suggestionList
    , toggleSwitch
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html
import Html.Attributes
import I18n
import Lib.Number as Number
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common exposing (hoverEffect, minWidthZero, uiClass)
import Ui.DesignTokens
    exposing
        ( minimumTargetSize
        , radiusControl
        , radiusPill
        , space12
        , space16
        , space2
        , space4
        , space8
        )
import Ui.Icon as Icon
import Ui.Theme exposing (Theme)
import Ui.Typography exposing (body, caption)


type alias InputConfig msg =
    { label : String, value : String, onChange : String -> msg }


{-| Where a search field's label lives. `LabelAbove` keeps the label as a
separate line; `LabelInside` folds it into the field as a placeholder while
retaining it as the accessible name, so a field can never have a visually
hidden label with no on-screen hint.
-}
type SearchLabel
    = LabelAbove String
    | LabelInside String


{-| elm-ui moves `Element.padding` on `Input.text` into the inner `<input>` as
`height`/`line-height` (`calc(1em + 2 * padding)`), so equal top and bottom
padding is what vertically centers the text at 44px. Setting an explicit
`Element.height` on `Input.text` lands on the outer wrapper instead and leaves
the text pinned to the top.
-}
fieldVerticalPadding : Int
fieldVerticalPadding =
    14


{-| Wide enough for the longest common unit ("kcal") at body size plus the
segment's horizontal padding, so the unit column does not resize as units change.
-}
unitFieldMinWidth : Int
unitFieldMinWidth =
    64


{-| Shared edge for every field, so plain inputs and segmented fields (unit
suffix, dropdown chevron) render the same border instead of elm-ui's default.
-}
inputBorder : Theme -> List (Element.Attribute msg)
inputBorder theme =
    [ Border.width 1, Border.color theme.divider ]


input : Theme -> InputConfig msg -> Element msg
input theme config =
    textInput theme [] config


{-| A read-only presentation of a field while its dialog is submitting.
`Input.text` routes `Element.htmlAttribute` to the real `<input>`, so this
disables the control rather than only its wrapper.
-}
disabledInput : Theme -> InputConfig msg -> Element msg
disabledInput theme config =
    textInput theme
        [ Element.htmlAttribute (Html.Attributes.disabled True)
        , Element.htmlAttribute (Html.Attributes.attribute "aria-disabled" "true")
        ]
        config


{-| Digits-only keypad for fields such as a barcode: no decimal separator. Passed
through `searchInput`'s `extraAttrs` so other search fields keep their keyboard.
-}
numericInputMode : Element.Attribute msg
numericInputMode =
    inputMode "numeric"


{-| Amount field: left-aligned tabular figures, with the decimal keypad on
mobile.
-}
numericInput : Theme -> InputConfig msg -> Element msg
numericInput theme config =
    textInput theme
        [ inputMode "decimal", Font.alignLeft, Font.variant Font.tabularNumbers ]
        { config | onChange = config.onChange << Number.normalizeDecimalSeparator }


inputMode : String -> Element.Attribute msg
inputMode mode =
    Element.htmlAttribute (Html.Attributes.attribute "inputmode" mode)


textInput : Theme -> List (Element.Attribute msg) -> InputConfig msg -> Element msg
textInput theme extraAttrs config =
    Input.text
        ([ Border.rounded radiusControl
         , Background.color theme.cardBg
         , Element.paddingEach
            { top = fieldVerticalPadding, right = 10, bottom = fieldVerticalPadding, left = 10 }
         , uiClass "ui-motion"
         ]
            ++ inputBorder theme
            ++ extraAttrs
        )
        { onChange = config.onChange
        , text = config.value
        , placeholder = Nothing
        , label = Input.labelAbove [] (fieldLabel theme config.label)
        }


searchInput :
    Theme
    ->
        { label : SearchLabel
        , text : String
        , onChange : String -> msg
        , extraAttrs : List (Element.Attribute msg)
        }
    -> Element msg
searchInput theme config =
    let
        ( labelElement, placeholderElement ) =
            case config.label of
                LabelAbove label ->
                    ( Input.labelAbove [ body, Font.medium ] (Element.text label), Nothing )

                LabelInside label ->
                    ( Input.labelHidden label
                    , Just (Input.placeholder [ Font.color theme.textMuted ] (Element.text label))
                    )
    in
    Input.text
        ([ Border.rounded radiusControl
         , Background.color theme.cardBg
         , Element.paddingEach
            { top = fieldVerticalPadding, right = 12, bottom = fieldVerticalPadding, left = 12 }
         , uiClass "ui-motion"
         ]
            ++ inputBorder theme
            ++ config.extraAttrs
        )
        { onChange = config.onChange
        , text = config.text
        , placeholder = placeholderElement
        , label = labelElement
        }


passwordInput : Theme -> InputConfig msg -> Element msg
passwordInput theme config =
    Input.currentPassword
        ([ Border.rounded radiusControl
         , Background.color theme.cardBg
         , Element.paddingEach
            { top = fieldVerticalPadding, right = 10, bottom = fieldVerticalPadding, left = 10 }
         , uiClass "ui-motion"
         ]
            ++ inputBorder theme
        )
        { onChange = config.onChange
        , text = config.value
        , placeholder = Nothing
        , label = Input.labelAbove [] (fieldLabel theme config.label)
        , show = False
        }


fieldLabel : Theme -> String -> Element msg
fieldLabel theme label =
    Element.el [ caption, Font.medium, Font.color theme.textPrimary ] (Element.text label)


decimalInputWithSuffix :
    Theme
    ->
        { label : String
        , text : String
        , suffix : String
        , onChange : String -> msg
        }
    -> Element msg
decimalInputWithSuffix theme config =
    let
        unitId : String
        unitId =
            String.toLower (String.replace " " "-" config.label) ++ "-unit"

        inputElement : Element msg
        inputElement =
            Input.text
                [ Element.width Element.fill
                , Element.paddingEach
                    { top = fieldVerticalPadding
                    , right = space12
                    , bottom = fieldVerticalPadding
                    , left = space16
                    }
                , Border.width 0
                , Border.rounded 0
                , Background.color theme.cardBg
                , body
                , Font.alignLeft
                , Font.variant Font.tabularNumbers
                , uiClass "ui-motion"
                , inputMode "decimal"
                , Element.htmlAttribute (Html.Attributes.attribute "aria-describedby" unitId)
                ]
                { onChange = config.onChange << Number.normalizeDecimalSeparator
                , text = config.text
                , placeholder = Nothing
                , label = Input.labelHidden config.label
                }

        unitElement : Element msg
        unitElement =
            Element.el
                [ Element.width (Element.shrink |> Element.minimum unitFieldMinWidth)
                , Element.height Element.fill
                , Element.paddingXY space16 0
                , Background.color theme.inputFill
                , Font.color theme.textMuted
                , Border.widthEach { top = 0, right = 0, bottom = 0, left = 1 }
                , Border.color theme.divider
                , Element.htmlAttribute (Html.Attributes.id unitId)
                ]
                (Element.el [ Element.centerX, Element.centerY ] (Element.text config.suffix))

        fieldInput : Element msg
        fieldInput =
            Element.row
                ([ Element.width Element.fill
                 , Element.height (Element.px minimumTargetSize)
                 , Border.rounded radiusControl
                 , Element.clip
                 , uiClass "ui-unit-field"
                 ]
                    ++ inputBorder theme
                )
                [ inputElement, unitElement ]
    in
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        [ fieldLabel theme config.label, fieldInput ]



-- Dropdowns


completionDropdown : Theme -> { height : Int, rows : List (Element msg) } -> Element msg
completionDropdown theme config =
    optionList theme { maxHeight = Just config.height, rows = config.rows }


optionList : Theme -> { maxHeight : Maybe Int, rows : List (Element msg) } -> Element msg
optionList theme config =
    if List.isEmpty config.rows then
        Element.none

    else
        Element.column
            ([ Element.width Element.fill
             , Element.spacing space2
             , Element.padding space4
             , Border.rounded radiusControl
             , Background.color theme.cardBg
             , Border.width 1
             , Border.color theme.divider
             , uiClass "ui-card-shadow"
             ]
                ++ (case config.maxHeight of
                        Just height ->
                            [ Element.height (Element.px height), Element.scrollbarY ]

                        Nothing ->
                            []
                   )
            )
            config.rows


completionRow :
    Theme
    ->
        { label : String
        , trailing : Maybe (Element msg)
        , onPress : msg
        }
    -> Element msg
completionRow theme config =
    optionRow theme
        { label = config.label
        , trailing = config.trailing
        , selected = False
        , onPress = config.onPress
        }


optionRow :
    Theme
    ->
        { label : String
        , trailing : Maybe (Element msg)
        , selected : Bool
        , onPress : msg
        }
    -> Element msg
optionRow theme config =
    optionRowView theme
        { label = config.label
        , trailing = config.trailing
        , selected = config.selected
        , onPress = config.onPress
        , disabled = False
        , extraAttributes = []
        }


{-| Toggle-like option row for choice controls that expose their selected
state. Plain dropdown/completion rows keep `optionRow` and avoid toggle ARIA.
-}
optionRowWithState :
    Theme
    ->
        { label : String
        , trailing : Maybe (Element msg)
        , selected : Bool
        , onPress : msg
        , disabled : Bool
        }
    -> Element msg
optionRowWithState theme config =
    optionRowView theme
        { label = config.label
        , trailing = config.trailing
        , selected = config.selected
        , onPress = config.onPress
        , disabled = config.disabled
        , extraAttributes =
            [ Element.htmlAttribute
                (Html.Attributes.attribute "aria-pressed"
                    (boolString config.selected)
                )
            , Element.htmlAttribute
                (Html.Attributes.attribute "aria-disabled"
                    (boolString config.disabled)
                )
            ]
        }


optionRowView :
    Theme
    ->
        { label : String
        , trailing : Maybe (Element msg)
        , selected : Bool
        , onPress : msg
        , disabled : Bool
        , extraAttributes : List (Element.Attribute msg)
        }
    -> Element msg
optionRowView theme config =
    let
        itemColor : Element.Color
        itemColor =
            if config.disabled then
                theme.textMuted

            else if config.selected then
                theme.solidControlFg

            else
                theme.textPrimary
    in
    Input.button
        ([ Element.width Element.fill
         , Element.paddingXY space12 10
         , Border.rounded radiusControl
         , Background.color
            (if config.selected then
                theme.brandBlue

             else
                theme.cardBg
            )
         , Font.color itemColor
         , Element.alpha
            (if config.disabled then
                0.6

             else
                1
            )
         , uiClass "ui-motion ui-pressable"
         ]
            ++ config.extraAttributes
        )
        { onPress =
            if config.disabled then
                Nothing

            else
                Just config.onPress
        , label =
            Element.row [ Element.width Element.fill, Element.spacing space8, minWidthZero ]
                [ Element.el [ Element.width Element.fill, Font.medium, minWidthZero ]
                    (Element.text config.label)
                , Maybe.withDefault Element.none config.trailing
                ]
        }


boolString : Bool -> String
boolString value =
    if value then
        "true"

    else
        "false"


suggestionList : Theme -> List (Element msg) -> Element msg
suggestionList theme items =
    optionList theme { maxHeight = Nothing, rows = items }


selectDropdown :
    Device
    -> Theme
    -> Language
    ->
        { label : String
        , selected : a
        , options : List ( a, String )
        , onChange : a -> msg
        , isOpen : Bool
        , onToggle : msg
        }
    -> Element msg
selectDropdown device theme language config =
    selectDropdownWithState device
        theme
        language
        { label = config.label
        , selected = config.selected
        , options = config.options
        , onChange = config.onChange
        , isOpen = config.isOpen
        , onToggle = config.onToggle
        , disabled = False
        }


selectDropdownWithState :
    Device
    -> Theme
    -> Language
    ->
        { label : String
        , selected : a
        , options : List ( a, String )
        , onChange : a -> msg
        , isOpen : Bool
        , onToggle : msg
        , disabled : Bool
        }
    -> Element msg
selectDropdownWithState device theme language config =
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
            optionRow theme
                { label = lbl
                , trailing = Nothing
                , selected = isSelected val
                , onPress = config.onChange val
                }

        optionsElement : Element msg
        optionsElement =
            Element.el
                [ Element.moveDown 4, Element.htmlAttribute (Html.Attributes.style "z-index" "20") ]
                (optionList theme
                    { maxHeight = Nothing, rows = List.map renderOption config.options }
                )

        triggerAnchor : List (Element.Attribute msg)
        triggerAnchor =
            if config.isOpen && not config.disabled then
                [ Element.width Element.fill, Element.below optionsElement ]

            else
                [ Element.width Element.fill ]

        selectedColor : Element.Color
        selectedColor =
            if config.disabled || selectedLabel == "" then
                theme.textMuted

            else
                theme.textPrimary

        fieldText : Element msg
        fieldText =
            Element.el
                [ Element.width Element.fill
                , Element.height Element.fill
                , Element.paddingEach { top = 0, right = space12, bottom = 0, left = space12 }
                ]
                (Element.el [ Element.centerY ]
                    (Element.el [ body, Font.color selectedColor ]
                        (Element.text
                            (if selectedLabel == "" then
                                I18n.t language TidUiSelectPlaceholder

                             else
                                selectedLabel
                            )
                        )
                    )
                )

        triggerDivider : Element msg
        triggerDivider =
            Element.el
                [ Element.width (Element.px 1)
                , Element.height Element.fill
                , Background.color theme.divider
                ]
                Element.none

        chevronSegment : Element msg
        chevronSegment =
            Element.el
                [ Element.height Element.fill
                , Element.paddingEach { top = 0, right = space12, bottom = 0, left = space12 }
                , Background.color theme.cardBg
                ]
                (Element.el [ Element.centerY ]
                    (Icon.view
                        { icon =
                            if config.isOpen then
                                Icon.ChevronUp

                            else
                                Icon.ChevronDown
                        , size = 20
                        , color = theme.textMuted
                        }
                    )
                )
    in
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        [ fieldLabel theme config.label
        , Element.el triggerAnchor
            (Input.button
                ([ Element.width Element.fill
                 , Element.height (Element.px minimumTargetSize)
                 , Border.rounded radiusControl
                 , Background.color theme.cardBg
                 , Element.clip
                 , Element.alpha
                    (if config.disabled then
                        0.6

                     else
                        1
                    )
                 , Element.htmlAttribute
                    (Html.Attributes.attribute "aria-disabled"
                        (boolString config.disabled)
                    )
                 , Element.htmlAttribute
                    (Html.Attributes.attribute "aria-expanded"
                        (boolString (config.isOpen && not config.disabled))
                    )
                 , uiClass "ui-motion"
                 , hoverEffect device [ Border.color theme.brandBlue ]
                 ]
                    ++ inputBorder theme
                )
                { onPress =
                    if config.disabled then
                        Nothing

                    else
                        Just config.onToggle
                , label =
                    Element.row [ Element.width Element.fill, Element.height Element.fill ]
                        [ fieldText, triggerDivider, chevronSegment ]
                }
            )
        ]



-- Boolean inputs


checkbox : Theme -> { label : String, checked : Bool, onChange : Bool -> msg } -> Element msg
checkbox theme config =
    Input.checkbox
        [ Element.width Element.fill
        , Element.height (Element.px minimumTargetSize)
        , Element.spacing space12
        ]
        { onChange = config.onChange
        , icon = checkboxIcon theme
        , checked = config.checked
        , label =
            Input.labelRight [ Element.height Element.fill ]
                (Element.el
                    [ body, Font.color theme.textPrimary, Element.centerY ]
                    (Element.text config.label)
                )
        }


checkboxIcon : Theme -> Bool -> Element msg
checkboxIcon theme isChecked =
    Element.el
        [ Element.width (Element.px 28)
        , Element.height (Element.px 28)
        , Border.rounded radiusPill
        , Border.width 1
        , Border.color
            (if isChecked then
                theme.brandBlue

             else
                theme.chipBorder
            )
        , Background.color
            (if isChecked then
                theme.brandBlue

             else
                theme.cardBg
            )
        , uiClass "ui-motion"
        , Element.centerY
        ]
        (if isChecked then
            Icon.view { icon = Icon.Check, size = 18, color = theme.solidControlFg }

         else
            Element.none
        )


toggleSwitch : Theme -> { label : String, isActive : Bool, onToggle : msg } -> Element msg
toggleSwitch theme config =
    Input.button
        [ Element.width (Element.px minimumTargetSize)
        , Element.height (Element.px minimumTargetSize)
        , Border.rounded radiusPill
        , uiClass "ui-pressable"
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" config.label)
        , Element.htmlAttribute
            (Html.Attributes.attribute "aria-pressed"
                (if config.isActive then
                    "true"

                 else
                    "false"
                )
            )
        ]
        { onPress = Just config.onToggle
        , label =
            Element.el
                [ Element.width (Element.px minimumTargetSize)
                , Element.height (Element.px 24)
                , Element.centerX
                , Element.centerY
                , Border.rounded radiusPill
                , Background.color theme.inputFill
                , Element.padding space2
                , uiClass
                    ("ui-toggle-track ui-motion"
                        ++ (if config.isActive then
                                " ui-toggle-on"

                            else
                                ""
                           )
                    )
                ]
                (Element.html (Html.span [ Html.Attributes.class "ui-toggle-thumb" ] []))
        }
