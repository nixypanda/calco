module Ui.Button exposing
    ( ButtonConfig
    , ButtonTone(..)
    , ButtonWidth(..)
    , SubmitState(..)
    , bottomActionButtons
    , iconButton
    , submittingOrIdle
    , textButton
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import Ui.Common exposing (hoverEffect, isSmall, uiClass)
import Ui.DesignTokens exposing (radiusPill, space12, space4)
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme exposing (Theme)


type SubmitState
    = Idle
    | Submitting
    | Disabled
    | Submitted


type ButtonTone
    = Primary
    | PrimaryOutline
    | Danger
    | DangerOutline
    | Ghost
    | GhostFilled


type ButtonWidth
    = ContentWidth
    | ResponsiveWidth
    | FullWidth


type alias ButtonConfig msg =
    { tone : ButtonTone
    , width : ButtonWidth
    , label : String
    , onPress : msg
    , submitState : Maybe SubmitState
    , submittingLabel : Maybe String
    , trailing : Maybe (Element msg)
    }


submittingOrIdle : Bool -> SubmitState
submittingOrIdle isSubmitting =
    if isSubmitting then
        Submitting

    else
        Idle


textButton : Device -> Theme -> ButtonConfig msg -> Element msg
textButton device theme config =
    let
        isActive : Bool
        isActive =
            case config.submitState of
                Nothing ->
                    True

                Just state ->
                    state == Idle

        label : String
        label =
            case ( config.submitState, config.submittingLabel ) of
                ( Just Submitting, Just subLabel ) ->
                    subLabel

                _ ->
                    config.label

        toneColors :
            { bg : Element.Color
            , fg : Element.Color
            , border : Element.Color
            , hoverBg : Element.Color
            , hoverFg : Element.Color
            , hoverBorder : Element.Color
            }
        toneColors =
            case config.tone of
                Primary ->
                    { bg =
                        if isActive then
                            theme.brandBlue

                        else
                            theme.brandBlueDisabled
                    , fg = Element.rgb255 255 255 255
                    , border =
                        if isActive then
                            theme.brandBlue

                        else
                            theme.brandBlueDisabled
                    , hoverBg = theme.brandBluePressed
                    , hoverFg = Element.rgb255 255 255 255
                    , hoverBorder = theme.brandBluePressed
                    }

                PrimaryOutline ->
                    let
                        c : Element.Color
                        c =
                            if isActive then
                                theme.brandBlue

                            else
                                theme.brandBlueDisabled
                    in
                    { bg = theme.cardBg
                    , fg = c
                    , border = c
                    , hoverBg = theme.brandBlueSoft
                    , hoverFg = theme.brandBlue
                    , hoverBorder = theme.brandBlue
                    }

                Danger ->
                    { bg = theme.dangerSolid
                    , fg = Element.rgb255 255 255 255
                    , border = theme.dangerSolid
                    , hoverBg = theme.dangerFg
                    , hoverFg = Element.rgb255 255 255 255
                    , hoverBorder = theme.dangerFg
                    }

                DangerOutline ->
                    { bg = theme.cardBg
                    , fg = theme.dangerFg
                    , border = theme.dangerFg
                    , hoverBg = theme.dangerBg
                    , hoverFg = theme.dangerFg
                    , hoverBorder = theme.dangerFg
                    }

                Ghost ->
                    { bg = Element.rgba255 0 0 0 0
                    , fg =
                        if isActive then
                            theme.brandBlue

                        else
                            theme.textMuted
                    , border = Element.rgba255 0 0 0 0
                    , hoverBg = theme.brandBlueSoft
                    , hoverFg = theme.brandBlue
                    , hoverBorder = Element.rgba255 0 0 0 0
                    }

                GhostFilled ->
                    { bg = theme.brandBlueSoft
                    , fg = theme.brandBlue
                    , border = Element.rgba255 0 0 0 0
                    , hoverBg = theme.brandBlueSoft
                    , hoverFg = theme.brandBlue
                    , hoverBorder = Element.rgba255 0 0 0 0
                    }

        widthAttr : Element.Attribute msg
        widthAttr =
            case config.width of
                FullWidth ->
                    Element.width Element.fill

                ContentWidth ->
                    Element.width Element.shrink

                ResponsiveWidth ->
                    if isSmall device then
                        Element.width Element.fill

                    else
                        Element.width Element.shrink

        borderAttrs : List (Element.Attribute msg)
        borderAttrs =
            case config.tone of
                Primary ->
                    []

                PrimaryOutline ->
                    [ Border.width 1 ]

                Danger ->
                    []

                DangerOutline ->
                    [ Border.width 1 ]

                Ghost ->
                    []

                GhostFilled ->
                    []

        isGhost : Bool
        isGhost =
            config.tone == Ghost || config.tone == GhostFilled

        isOutline : Bool
        isOutline =
            config.tone == PrimaryOutline || config.tone == DangerOutline
    in
    Input.button
        ([ Background.color toneColors.bg
         , Font.color toneColors.fg
         , Border.rounded radiusPill
         , widthAttr
         , Element.height (Element.px 48)
         , Element.paddingEach { top = 17, right = 16, bottom = 17, left = 16 }
         , Font.medium
         , Font.size 14
         , uiClass "ui-motion ui-pressable"
         ]
            ++ (if isActive then
                    [ hoverEffect device
                        [ Background.color toneColors.hoverBg
                        , Font.color toneColors.hoverFg
                        ]
                    ]

                else
                    []
               )
            ++ (if isGhost then
                    []

                else
                    [ Font.center ]
               )
            ++ borderAttrs
            ++ (if isOutline && isActive then
                    [ Border.color toneColors.border
                    , hoverEffect device
                        [ Background.color toneColors.hoverBg
                        , Font.color toneColors.hoverFg
                        , Border.color toneColors.hoverBorder
                        ]
                    ]

                else if isOutline then
                    [ Border.color toneColors.border ]

                else
                    []
               )
        )
        { onPress =
            if isActive then
                Just config.onPress

            else
                Nothing
        , label =
            case config.trailing of
                Nothing ->
                    Element.text label

                Just trailingEl ->
                    Element.row [ Element.width Element.fill, Element.spacing space4 ]
                        [ Element.text label
                        , Element.el [ Element.alignRight ] trailingEl
                        ]
        }


bottomActionButtons :
    Device
    -> Theme
    -> List { label : String, onPress : msg, tone : ButtonTone }
    -> Element msg
bottomActionButtons device theme buttons =
    let
        buttonView : { label : String, onPress : msg, tone : ButtonTone } -> Element msg
        buttonView config =
            Element.el [ Element.width Element.fill ]
                (textButton device
                    theme
                    { tone = config.tone
                    , width = FullWidth
                    , label = config.label
                    , onPress = config.onPress
                    , submitState = Nothing
                    , submittingLabel = Nothing
                    , trailing = Nothing
                    }
                )

        buttonElements : List (Element msg)
        buttonElements =
            List.map buttonView buttons
    in
    case buttonElements of
        [] ->
            Element.none

        [ onlyButton ] ->
            Element.column
                [ Element.width Element.fill
                , Element.spacing space12
                ]
                [ onlyButton ]

        [ firstButton, secondButton ] ->
            Element.row
                [ Element.width Element.fill
                , Element.spacing space12
                ]
                [ firstButton, secondButton ]

        _ ->
            Element.column
                [ Element.width Element.fill
                , Element.spacing space12
                ]
                buttonElements


iconButton :
    Device
    -> Theme
    -> { icon : Icon, title : String, onPress : Maybe msg, tone : ButtonTone }
    -> Element msg
iconButton device theme config =
    let
        isActive : Bool
        isActive =
            config.onPress /= Nothing

        iconTone :
            { iconColor : Element.Color
            , bgColor : Element.Color
            , border : Element.Color
            , hoverBg : Element.Color
            , hoverBorder : Element.Color
            }
        iconTone =
            case config.tone of
                Danger ->
                    { iconColor = theme.dangerFg
                    , bgColor = theme.cardBg
                    , border = theme.dangerFg
                    , hoverBg = theme.dangerSolid
                    , hoverBorder = theme.dangerSolid
                    }

                _ ->
                    { iconColor =
                        if isActive then
                            theme.textPrimary

                        else
                            theme.textMuted
                    , bgColor =
                        if isActive then
                            theme.cardBg

                        else
                            theme.inputFill
                    , border = theme.divider
                    , hoverBg = theme.brandBlueSoft
                    , hoverBorder = theme.brandBlue
                    }

        iconSize : Int
        iconSize =
            case config.icon of
                Icon.Close ->
                    18

                _ ->
                    22
    in
    Input.button
        [ Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Background.color iconTone.bgColor
        , Font.color iconTone.iconColor
        , Font.center
        , Border.rounded radiusPill
        , Border.width 1
        , Border.color iconTone.border
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device
            [ Background.color iconTone.hoverBg
            , Border.color iconTone.hoverBorder
            ]
        , Element.htmlAttribute (Html.Attributes.title config.title)
        ]
        { onPress = config.onPress
        , label =
            Element.el [ Element.centerX, Element.centerY ]
                (Icon.view
                    { icon = config.icon
                    , size = iconSize
                    , color = iconTone.iconColor
                    }
                )
        }
