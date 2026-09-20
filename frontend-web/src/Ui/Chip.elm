module Ui.Chip exposing
    ( badge
    , chip
    , chipBackground
    , chips
    , coloredPill
    , removableChip
    , statusBadge
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html exposing (Html)
import Html.Attributes
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common exposing (uiClass)
import Ui.DesignTokens exposing (minimumTargetSize, radiusPill, space8)
import Ui.Icon as Icon
import Ui.Theme exposing (Theme)
import Ui.Typography exposing (caption)


chipBackground : Theme -> Bool -> Element.Color
chipBackground theme selected =
    if selected then
        theme.chipSelectedBg

    else
        theme.chipBg


chipForeground : Theme -> Bool -> Element.Color
chipForeground theme selected =
    if selected then
        theme.chipSelectedFg

    else
        theme.textPrimary


chip :
    Theme
    ->
        { label : String
        , selected : Bool
        }
    -> Element msg
chip theme config =
    Element.html (chipHtml theme config)


removableChip :
    Theme
    -> Language
    -> { label : String, onRemove : msg }
    -> Element msg
removableChip theme language config =
    let
        removeSize : Int
        removeSize =
            28
    in
    Element.row
        [ Background.color (chipBackground theme False)
        , Font.color (chipForeground theme False)
        , Border.rounded radiusPill
        , Element.paddingEach { top = 0, right = 4, bottom = 0, left = 10 }
        , Element.spacing space8
        , caption
        , Font.medium
        ]
        [ Element.text config.label
        , Input.button
            [ Element.width (Element.px minimumTargetSize)
            , Element.height (Element.px minimumTargetSize)
            , Font.color theme.dangerFg
            , Font.center
            , Border.rounded radiusPill
            , uiClass "ui-chip-remove-target ui-pressable"
            , Element.htmlAttribute
                (Html.Attributes.attribute
                    "aria-label"
                    (I18n.t language (TidUiRemoveNamed config.label))
                )
            ]
            { onPress = Just config.onRemove
            , label =
                Element.el
                    [ Element.width (Element.px removeSize)
                    , Element.height (Element.px removeSize)
                    , Element.centerX
                    , Element.centerY
                    , Background.color theme.cardBg
                    , Border.rounded radiusPill
                    , Border.width 1
                    , Border.color theme.dangerFg
                    , uiClass "ui-chip-remove-visual ui-motion"
                    ]
                    (Icon.view
                        { icon = Icon.Close
                        , size = 16
                        , color = theme.dangerFg
                        }
                    )
            }
        ]


chipHtml :
    Theme
    ->
        { label : String
        , selected : Bool
        }
    -> Html msg
chipHtml _ config =
    let
        chipClass : String
        chipClass =
            "ui-chip"
                ++ (if config.selected then
                        " ui-chip-selected"

                    else
                        ""
                   )
    in
    Html.span
        [ Html.Attributes.class chipClass ]
        [ Html.text config.label ]


chips : Theme -> List String -> Element msg
chips theme strings =
    if List.isEmpty strings then
        Element.none

    else
        Element.html
            (Html.div
                [ Html.Attributes.class "ui-chip-group" ]
                (List.map
                    (\c ->
                        chipHtml theme { label = c, selected = False }
                    )
                    strings
                )
            )


coloredPill :
    { label : String
    , bg : Element.Color
    , fg : Element.Color
    }
    -> Element msg
coloredPill config =
    pill 10 config


pill :
    Int
    ->
        { label : String
        , bg : Element.Color
        , fg : Element.Color
        }
    -> Element msg
pill horizontalPadding config =
    Element.el
        [ Background.color config.bg
        , Font.color config.fg
        , Border.rounded radiusPill
        , Element.paddingEach
            { top = 4
            , right = horizontalPadding
            , bottom = 4
            , left = horizontalPadding
            }
        , caption
        , Font.medium
        ]
        (Element.text config.label)


badge : Theme -> String -> Element msg
badge theme label =
    pill 8
        { label = label
        , bg = theme.inputFill
        , fg = theme.textPrimary
        }


statusBadge : Theme -> String -> Element msg
statusBadge theme status =
    coloredPill
        { label = status
        , bg =
            if status == "active" then
                theme.statusActiveBg

            else
                theme.statusDisabledBg
        , fg =
            if status == "active" then
                theme.statusGreen

            else
                theme.statusRed
        }
