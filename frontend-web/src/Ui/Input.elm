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
    , selectDropdownLabelHidden
    , selectDropdownTriggerId
    , selectDropdownWithState
    , suggestionList
    , toggleSwitch
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html
import Html.Attributes
import Html.Events
import I18n
import Json.Decode as Decode
import Lib.Number as Number
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common exposing (dataAttribute, hoverEffect, minWidthZero, testId, uiClass)
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


fieldWrapper : Element msg -> Element msg
fieldWrapper control =
    Element.el [ Element.width Element.fill, testId "field" ] control


textInput : Theme -> List (Element.Attribute msg) -> InputConfig msg -> Element msg
textInput theme extraAttrs config =
    fieldWrapper
        (Input.text
            ([ Border.rounded radiusControl
             , Background.color theme.cardBg
             , Element.paddingEach
                { top = fieldVerticalPadding
                , right = 10
                , bottom = fieldVerticalPadding
                , left = 10
                }
             , uiClass "ui-motion"
             , testId "field-control"
             ]
                ++ inputBorder theme
                ++ extraAttrs
            )
            { onChange = config.onChange
            , text = config.value
            , placeholder = Nothing
            , label = Input.labelAbove [] (fieldLabel theme config.label)
            }
        )


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
    fieldWrapper
        (Input.text
            ([ Border.rounded radiusControl
             , Background.color theme.cardBg
             , Element.paddingEach
                { top = fieldVerticalPadding
                , right = 12
                , bottom = fieldVerticalPadding
                , left = 12
                }
             , uiClass "ui-motion"
             , testId "field-control"
             ]
                ++ inputBorder theme
                ++ config.extraAttrs
            )
            { onChange = config.onChange
            , text = config.text
            , placeholder = placeholderElement
            , label = labelElement
            }
        )


passwordInput : Theme -> InputConfig msg -> Element msg
passwordInput theme config =
    fieldWrapper
        (Input.currentPassword
            ([ Border.rounded radiusControl
             , Background.color theme.cardBg
             , Element.paddingEach
                { top = fieldVerticalPadding
                , right = 10
                , bottom = fieldVerticalPadding
                , left = 10
                }
             , uiClass "ui-motion"
             , testId "field-control"
             ]
                ++ inputBorder theme
            )
            { onChange = config.onChange
            , text = config.value
            , placeholder = Nothing
            , label = Input.labelAbove [] (fieldLabel theme config.label)
            , show = False
            }
        )


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
                theme.chipSelectedFg

            else
                theme.textPrimary
    in
    Input.button
        ([ Element.width Element.fill
         , Element.paddingXY space12 10
         , Border.rounded radiusControl

         -- The chip selection palette keeps the selected foreground at 4.5:1
         -- or better in both themes; white on the solid brand fill does not.
         , Background.color
            (if config.selected then
                theme.chipSelectedBg

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
    selectDropdownView
        device
        theme
        language
        { label = config.label
        , selected = config.selected
        , options = config.options
        , onChange = config.onChange
        , isOpen = config.isOpen
        , onToggle = config.onToggle
        , disabled = config.disabled
        }


{-| The trigger id for `selectDropdownLabelHidden`, so a page can return focus
to the control after a choice.
-}
selectDropdownTriggerId : String -> String
selectDropdownTriggerId id =
    id ++ "-trigger"


{-| A select-only combobox for a control whose visible title already lives in
the surrounding row. The trigger carries the accessible name and selected value,
exposes the listbox state, supports arrow/Home/End/Escape keys, and dismisses on
an outside click. Options expose their selected state for assistive technology;
the chosen option uses the blue/neutral field palette rather than the chip fill.
-}
selectDropdownLabelHidden :
    Device
    -> Theme
    -> Language
    ->
        { id : String
        , label : String
        , selected : a
        , options : List ( a, String )
        , onChange : a -> msg
        , isOpen : Bool
        , onToggle : msg
        , active : Maybe a
        , onActiveChanged : Maybe a -> msg
        , onClose : msg
        }
    -> Element msg
selectDropdownLabelHidden device theme language config =
    let
        triggerId : String
        triggerId =
            selectDropdownTriggerId config.id

        listboxId : String
        listboxId =
            config.id ++ "-listbox"

        selectedLabel : String
        selectedLabel =
            selectedOptionLabel config.selected config.options

        activeOptionId : Maybe String
        activeOptionId =
            if config.isOpen then
                config.active
                    |> Maybe.andThen (optionIndex config.options)
                    |> Maybe.map (optionId listboxId)

            else
                Nothing

        triggerAttributes : List (Element.Attribute msg)
        triggerAttributes =
            [ Element.width Element.fill
            , Element.height (Element.px minimumTargetSize)
            , Border.rounded radiusControl
            , Background.color theme.cardBg
            , Element.clip
            , Element.pointer
            , Element.htmlAttribute (Html.Attributes.id triggerId)
            , Element.htmlAttribute (Html.Attributes.tabindex 0)
            , Element.htmlAttribute (Html.Attributes.attribute "role" "combobox")
            , Element.htmlAttribute (Html.Attributes.attribute "aria-haspopup" "listbox")
            , Element.htmlAttribute
                (Html.Attributes.attribute "aria-expanded" (boolString config.isOpen))
            , Element.htmlAttribute
                (Html.Attributes.attribute
                    "aria-label"
                    (config.label ++ ": " ++ selectedLabel)
                )
            , Element.htmlAttribute
                (keydownHandler
                    { isOpen = config.isOpen
                    , selected = config.selected
                    , options = config.options
                    , active = config.active
                    , onToggle = config.onToggle
                    , onChange = config.onChange
                    , onActiveChanged = config.onActiveChanged
                    , onClose = config.onClose
                    }
                )
            , Element.htmlAttribute (Html.Events.onClick config.onToggle)
            , uiClass "ui-motion"
            , testId "field-control"
            , hoverEffect device [ Border.color theme.brandBlue ]
            ]
                ++ (if config.isOpen then
                        [ Element.htmlAttribute
                            (Html.Attributes.attribute "aria-controls" listboxId)
                        ]

                    else
                        []
                   )
                ++ (case activeOptionId of
                        Just id ->
                            [ Element.htmlAttribute
                                (Html.Attributes.attribute "aria-activedescendant" id)
                            ]

                        Nothing ->
                            []
                   )
                ++ inputBorder theme

        renderOption : Int -> ( a, String ) -> Element msg
        renderOption index ( value, label ) =
            dropdownOption theme
                { id = optionId listboxId index
                , label = label
                , selected = value == config.selected
                , onPress = config.onChange value
                }

        optionsElement : Element msg
        optionsElement =
            Element.el
                [ Element.width Element.fill
                , Element.moveDown 4
                , Element.htmlAttribute (Html.Attributes.id listboxId)
                , Element.htmlAttribute (Html.Attributes.attribute "role" "listbox")
                , Element.htmlAttribute (Html.Attributes.attribute "aria-label" config.label)
                ]
                (optionList theme
                    { maxHeight = Nothing
                    , rows = List.indexedMap renderOption config.options
                    }
                )

        triggerAnchor : List (Element.Attribute msg)
        triggerAnchor =
            [ Element.width Element.fill
            , uiClass "ui-select-anchor"
            ]
                ++ (if config.isOpen then
                        [ Element.below optionsElement ]

                    else
                        []
                   )

        backdrop : List (Element msg)
        backdrop =
            if config.isOpen then
                [ Element.el
                    [ Element.width Element.fill
                    , Element.height Element.fill
                    , uiClass "ui-select-backdrop"
                    , testId (config.id ++ "-backdrop")
                    , Element.htmlAttribute (Html.Attributes.attribute "aria-hidden" "true")
                    , Element.htmlAttribute (Html.Events.onClick config.onClose)
                    ]
                    Element.none
                ]

            else
                []
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing space4
        , testId "field"
        , dataAttribute "data-field-kind" "select"
        ]
        (Element.el triggerAnchor
            (Element.el triggerAttributes
                (Element.row
                    [ Element.width Element.fill
                    , Element.height Element.fill
                    ]
                    [ dropdownFieldText theme language False selectedLabel
                    , dropdownDivider theme
                    , dropdownChevronSegment theme config.isOpen
                    ]
                )
            )
            :: backdrop
        )


selectDropdownView :
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
selectDropdownView device theme language config =
    let
        selectedLabel : String
        selectedLabel =
            selectedOptionLabel config.selected config.options

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
                [ Element.moveDown 4
                , Element.htmlAttribute (Html.Attributes.style "z-index" "20")
                ]
                (optionList theme
                    { maxHeight = Nothing, rows = List.map renderOption config.options }
                )

        triggerAnchor : List (Element.Attribute msg)
        triggerAnchor =
            if config.isOpen && not config.disabled then
                [ Element.width Element.fill, Element.below optionsElement ]

            else
                [ Element.width Element.fill ]
    in
    Element.column
        [ Element.width Element.fill
        , Element.spacing space4
        , testId "field"
        , dataAttribute "data-field-kind" "select"
        ]
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
                 , testId "field-control"
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
                        [ dropdownFieldText theme language config.disabled selectedLabel
                        , dropdownDivider theme
                        , dropdownChevronSegment theme config.isOpen
                        ]
                }
            )
        ]


selectedOptionLabel : a -> List ( a, String ) -> String
selectedOptionLabel selected options =
    options
        |> List.filter (\( value, _ ) -> value == selected)
        |> List.head
        |> Maybe.map Tuple.second
        |> Maybe.withDefault ""


dropdownFieldText : Theme -> Language -> Bool -> String -> Element msg
dropdownFieldText theme language disabled selectedLabel =
    let
        textColor : Element.Color
        textColor =
            if disabled || String.isEmpty selectedLabel then
                theme.textMuted

            else
                theme.textPrimary
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.paddingEach { top = 0, right = space12, bottom = 0, left = space12 }
        ]
        (Element.el [ Element.centerY ]
            (Element.el [ body, Font.color textColor ]
                (Element.text
                    (if String.isEmpty selectedLabel then
                        I18n.t language TidUiSelectPlaceholder

                     else
                        selectedLabel
                    )
                )
            )
        )


dropdownDivider : Theme -> Element msg
dropdownDivider theme =
    Element.el
        [ Element.width (Element.px 1)
        , Element.height Element.fill
        , Background.color theme.divider
        ]
        Element.none


dropdownChevronSegment : Theme -> Bool -> Element msg
dropdownChevronSegment theme isOpen =
    Element.el
        [ Element.height Element.fill
        , Element.paddingEach { top = 0, right = space12, bottom = 0, left = space12 }
        , Background.color theme.cardBg
        ]
        (Element.el [ Element.centerY ]
            (Icon.view
                { icon =
                    if isOpen then
                        Icon.ChevronUp

                    else
                        Icon.ChevronDown
                , size = 20
                , color = theme.textMuted
                }
            )
        )


dropdownOption :
    Theme
    -> { id : String, label : String, selected : Bool, onPress : msg }
    -> Element msg
dropdownOption theme config =
    Element.el
        ([ Element.width Element.fill
         , Element.paddingXY space12 10
         , Border.rounded radiusControl
         , Background.color
            (if config.selected then
                theme.brandBlueSoft

             else
                theme.cardBg
            )
         , Font.color theme.textPrimary
         , Element.pointer
         , Element.htmlAttribute (Html.Attributes.id config.id)
         , Element.htmlAttribute (Html.Attributes.attribute "role" "option")
         , Element.htmlAttribute
            (Html.Attributes.attribute "aria-selected" (boolString config.selected))
         , Element.htmlAttribute (Html.Events.onClick config.onPress)
         , uiClass "ui-motion ui-pressable"
         ]
            ++ (if config.selected then
                    [ Font.medium ]

                else
                    [ Element.mouseOver [ Background.color theme.inputFill ] ]
               )
        )
        (Element.row [ Element.width Element.fill, Element.spacing space8, minWidthZero ]
            [ Element.el [ Element.width Element.fill, minWidthZero ]
                (Element.text config.label)
            , if config.selected then
                Icon.view { icon = Icon.Check, size = 18, color = theme.textPrimary }

              else
                Element.none
            ]
        )


optionIndex : List ( a, String ) -> a -> Maybe Int
optionIndex options selected =
    options
        |> List.indexedMap (\index ( value, _ ) -> ( index, value ))
        |> List.filter (\( _, value ) -> value == selected)
        |> List.head
        |> Maybe.map Tuple.first


optionId : String -> Int -> String
optionId listboxId index =
    listboxId ++ "-option-" ++ String.fromInt index


type alias KeydownResult msg =
    { message : msg
    , stopPropagation : Bool
    , preventDefault : Bool
    }


keydownHandler :
    { isOpen : Bool
    , selected : a
    , options : List ( a, String )
    , active : Maybe a
    , onToggle : msg
    , onChange : a -> msg
    , onActiveChanged : Maybe a -> msg
    , onClose : msg
    }
    -> Html.Attribute msg
keydownHandler config =
    Html.Events.custom "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen (keydownDecoder config)
        )


keydownDecoder :
    { isOpen : Bool
    , selected : a
    , options : List ( a, String )
    , active : Maybe a
    , onToggle : msg
    , onChange : a -> msg
    , onActiveChanged : Maybe a -> msg
    , onClose : msg
    }
    -> String
    -> Decode.Decoder (KeydownResult msg)
keydownDecoder config key =
    case key of
        "Escape" ->
            if config.isOpen then
                handled config.onClose

            else
                Decode.fail "Escape with the menu closed"

        "Tab" ->
            if config.isOpen then
                handledWithoutDefault config.onClose

            else
                Decode.fail "Tab with the menu closed"

        "ArrowDown" ->
            if config.isOpen then
                let
                    next : Maybe a
                    next =
                        nextOption config.options config.active config.selected
                in
                handled (config.onActiveChanged next)

            else
                handled config.onToggle

        "ArrowUp" ->
            if config.isOpen then
                let
                    previous : Maybe a
                    previous =
                        previousOption config.options config.active config.selected
                in
                handled (config.onActiveChanged previous)

            else
                handled config.onToggle

        "Home" ->
            if config.isOpen then
                handled (config.onActiveChanged (firstOption config.options))

            else
                Decode.fail "Home with the menu closed"

        "End" ->
            if config.isOpen then
                handled (config.onActiveChanged (lastOption config.options))

            else
                Decode.fail "End with the menu closed"

        "Enter" ->
            chooseActiveOption config

        " " ->
            chooseActiveOption config

        "Spacebar" ->
            chooseActiveOption config

        _ ->
            Decode.fail "Unhandled key"


chooseActiveOption :
    { isOpen : Bool
    , selected : a
    , options : List ( a, String )
    , active : Maybe a
    , onToggle : msg
    , onChange : a -> msg
    , onActiveChanged : Maybe a -> msg
    , onClose : msg
    }
    -> Decode.Decoder (KeydownResult msg)
chooseActiveOption config =
    if config.isOpen then
        handled (config.onChange (Maybe.withDefault config.selected config.active))

    else
        handled config.onToggle


handled : msg -> Decode.Decoder (KeydownResult msg)
handled message =
    handledWith message True


handledWithoutDefault : msg -> Decode.Decoder (KeydownResult msg)
handledWithoutDefault message =
    handledWith message False


handledWith : msg -> Bool -> Decode.Decoder (KeydownResult msg)
handledWith message preventDefault =
    Decode.succeed
        { message = message
        , stopPropagation = True
        , preventDefault = preventDefault
        }


nextOption : List ( a, String ) -> Maybe a -> a -> Maybe a
nextOption options active selected =
    case List.length options of
        0 ->
            Nothing

        count ->
            optionAt options (modBy count (currentOptionIndex options active selected + 1))


previousOption : List ( a, String ) -> Maybe a -> a -> Maybe a
previousOption options active selected =
    case List.length options of
        0 ->
            Nothing

        count ->
            optionAt options (modBy count (currentOptionIndex options active selected - 1))


firstOption : List ( a, String ) -> Maybe a
firstOption options =
    options
        |> List.head
        |> Maybe.map Tuple.first


lastOption : List ( a, String ) -> Maybe a
lastOption options =
    options
        |> List.reverse
        |> List.head
        |> Maybe.map Tuple.first


currentOptionIndex : List ( a, String ) -> Maybe a -> a -> Int
currentOptionIndex options active selected =
    case active |> Maybe.andThen (optionIndex options) of
        Just index ->
            index

        Nothing ->
            optionIndex options selected |> Maybe.withDefault 0


optionAt : List ( a, String ) -> Int -> Maybe a
optionAt options index =
    options
        |> List.drop index
        |> List.head
        |> Maybe.map Tuple.first



-- Boolean inputs


checkbox : Theme -> { label : String, checked : Bool, onChange : Bool -> msg } -> Element msg
checkbox theme config =
    Input.checkbox
        [ Element.width Element.fill
        , Element.height (Element.px minimumTargetSize)
        , Element.spacing space12
        , testId "checkbox-row"
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
        , testId "field"
        , Region.description config.label
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
