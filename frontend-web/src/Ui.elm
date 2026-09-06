module Ui exposing
    ( ButtonConfig
    , ButtonTone(..)
    , ButtonWidth(..)
    , InputConfig
    , PageHeaderSubtitle(..)
    , SubmitState(..)
    , accentDot
    , badge
    , bottomActionButtons
    , bottomNavBar
    , bottomNavTab
    , card
    , chip
    , chipBackground
    , chips
    , coloredPill
    , completionDropdown
    , completionRow
    , decimalInput
    , decimalInputWithSuffix
    , detailRow
    , dotSeparated
    , drawerItem
    , drawerPanel
    , emptyState
    , errorBanner
    , fieldLabel
    , formSection
    , hairline
    , heroCard
    , iconButton
    , input
    , isSmall
    , layout
    , linearProgress
    , listCard
    , listRow
    , loading
    , maybeErrorBanner
    , menuCard
    , modalOverlay
    , numericInputMode
    , optionRow
    , pageContainer
    , pageHeader
    , passwordInput
    , removableChip
    , scrimOverlay
    , searchInput
    , section
    , selectDropdown
    , skeletonBar
    , skeletonBarCustom
    , skeletonButton
    , skeletonCard
    , skeletonInput
    , skeletonListRow
    , skeletonLoading
    , statusBadge
    , submittingOrIdle
    , suggestionList
    , textButton
    , toggleSwitch
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Lib.Number as Number
import Ui.DesignTokens
    exposing
        ( radiusCard
        , radiusControl
        , radiusHairline
        , radiusPill
        , radiusSmall
        , space12
        , space16
        , space2
        , space20
        , space4
        , space8
        )
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme exposing (Theme)
import Ui.Typography
    exposing
        ( body
        , caption
        , minWidthZero
        , mutedBody
        , mutedParagraph
        , sectionTitle
        , subsectionTitle
        , uiClass
        )



-- Surfaces & layout


cardShadow : Theme -> Element.Attribute msg
cardShadow _ =
    uiClass "ui-card-shadow"


type PageHeaderSubtitle
    = SubtitleText String
    | SubtitleMeta { items : List String, separator : String }
    | SubtitleMetaLines { lines : List (List String), separator : String }


layout : Theme -> Element msg -> Element msg
layout theme content =
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color theme.pageBg
        , Font.family [ Font.typeface "Inter", Font.sansSerif ]
        , Font.color theme.textPrimary
        , body
        , uiClass "ui-theme-root"
        ]
        [ content ]


pageContainer : Device -> List (Element msg) -> Element msg
pageContainer _ children =
    Element.column
        [ Element.centerX
        , Element.width (Element.fill |> Element.maximum 960)
        , Element.spacing space16
        , Element.paddingEach
            { top = space16
            , right = space16
            , bottom = space16
            , left = space16
            }
        ]
        children


isSmall : Device -> Bool
isSmall device =
    device.class == Element.Phone


hoverEffect : Device -> List Element.Decoration -> Element.Attribute msg
hoverEffect device attrs =
    if isSmall device then
        Element.mouseOver []

    else
        Element.mouseOver attrs


card : Theme -> List (Element msg) -> Element msg
card theme children =
    Element.column
        [ Element.width Element.fill
        , Background.color theme.cardBg
        , Border.rounded radiusCard
        , cardShadow theme
        , uiClass "ui-surface"
        , Element.padding space20
        , Element.spacing space12
        ]
        children


heroCard :
    Theme
    ->
        { header : Element msg
        , body : List (Element msg)
        , mediaHeader :
            Maybe
                { height : Int
                , backgroundAttrs : List (Element.Attribute msg)
                , fade : Maybe (Element msg)
                , contentPadding :
                    { top : Int
                    , right : Int
                    , bottom : Int
                    , left : Int
                    }
                }
        }
    -> Element msg
heroCard theme config =
    let
        headerElement : Element msg
        headerElement =
            case config.mediaHeader of
                Just media ->
                    Element.el
                        ([ Element.width Element.fill
                         , Element.height (Element.px media.height)
                         , Border.roundEach
                            { topLeft = radiusCard
                            , topRight = radiusCard
                            , bottomLeft = 0
                            , bottomRight = 0
                            }
                         , Element.clip
                         ]
                            ++ (case media.fade of
                                    Just fade ->
                                        [ Element.inFront fade ]

                                    Nothing ->
                                        []
                               )
                            ++ [ Element.inFront
                                    (Element.el
                                        [ Element.width Element.fill
                                        , Element.height Element.fill
                                        , Element.paddingEach media.contentPadding
                                        ]
                                        config.header
                                    )
                               ]
                            ++ media.backgroundAttrs
                        )
                        Element.none

                Nothing ->
                    config.header
    in
    Element.column
        [ Element.width Element.fill
        , Background.color theme.cardBg
        , Border.rounded radiusCard
        , cardShadow theme
        , Element.spacing 0
        ]
        [ headerElement
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = 0, right = space20, bottom = space20, left = space20 }
            , Element.spacing space12
            ]
            config.body
        ]


pageHeader :
    Theme
    ->
        { leading : Maybe (Element msg)
        , title : Element msg
        , subtitle : Maybe PageHeaderSubtitle
        , actions : List (Element msg)
        }
    -> Element msg
pageHeader theme config =
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
                [ Element.width Element.fill
                , Element.spacing space4
                , minWidthZero
                ]
                (config.title
                    :: (case config.subtitle of
                            Just subtitle ->
                                [ pageHeaderSubtitle theme subtitle ]

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
        , minWidthZero
        ]
        [ leadingElement, titleColumn, actionsRow ]


pageHeaderSubtitle : Theme -> PageHeaderSubtitle -> Element msg
pageHeaderSubtitle theme subtitle =
    case subtitle of
        SubtitleText text ->
            mutedBody theme text

        SubtitleMeta meta ->
            Element.paragraph
                [ Font.color theme.textMuted
                , body
                , Element.width Element.fill
                , minWidthZero
                ]
                (separatedInline meta)

        SubtitleMetaLines meta ->
            Element.column
                [ Element.width Element.fill
                , Element.spacing space2
                , minWidthZero
                ]
                (List.map
                    (\items ->
                        Element.paragraph
                            [ Font.color theme.textMuted
                            , body
                            , Element.width Element.fill
                            , minWidthZero
                            ]
                            (separatedInline
                                { items = items, separator = meta.separator }
                            )
                    )
                    meta.lines
                )


separatedInline : { items : List String, separator : String } -> List (Element msg)
separatedInline meta =
    meta.items
        |> List.map Element.text
        |> List.intersperse (Element.text meta.separator)


section :
    Theme
    ->
        { header : Maybe (Element msg)
        , body : List (Element msg)
        , footer : Maybe (Element msg)
        }
    -> Element msg
section theme config =
    let
        headerSlot : List (Element msg)
        headerSlot =
            case config.header of
                Just el ->
                    [ el, hairline theme ]

                Nothing ->
                    []

        footerSlot : List (Element msg)
        footerSlot =
            case config.footer of
                Just el ->
                    [ hairline theme, el ]

                Nothing ->
                    []
    in
    card theme (headerSlot ++ config.body ++ footerSlot)


formSection : Theme -> String -> List (Element msg) -> Element msg
formSection theme title content =
    section theme
        { header = Just (subsectionTitle theme title)
        , body = content
        , footer = Nothing
        }


listCard : Theme -> { rows : List (Element msg), footer : Maybe (Element msg) } -> Element msg
listCard theme config =
    section theme
        { header = Nothing
        , body =
            if List.isEmpty config.rows then
                [ emptyListBody theme ]

            else
                List.intersperse (hairline theme) config.rows
        , footer = config.footer
        }


emptyListBody : Theme -> Element msg
emptyListBody theme =
    Element.el
        [ Element.width Element.fill
        , Element.padding space16
        ]
        (mutedParagraph theme "No items yet.")


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
            [ Element.width Element.fill
            , uiClass "ui-motion ui-pressable"
            ]
            { onPress = Just config.onSelect
            , label =
                Element.row
                    [ Element.width Element.fill
                    , Element.spacing space12
                    , minWidthZero
                    ]
                    [ listRowLeading config.leading
                    , Element.column
                        [ Element.width Element.fill
                        , Element.spacing space4
                        , Element.alignTop
                        , minWidthZero
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
        , Element.paddingEach { top = space2, right = 0, bottom = 0, left = 0 }
        , Element.alignTop
        ]
        (case leading of
            first :: _ ->
                first

            [] ->
                Element.none
        )



-- States


loading : Theme -> String -> Element msg
loading theme message =
    Element.el
        [ Font.color theme.textMuted ]
        (Element.text message)


emptyState : Theme -> String -> Element msg
emptyState theme message =
    card theme
        [ Element.paragraph
            [ Font.color theme.textMuted
            , Font.center
            , Element.padding space8
            ]
            [ Element.text message ]
        ]


maybeErrorBanner : Theme -> Maybe String -> Element msg
maybeErrorBanner theme maybeError =
    Maybe.withDefault Element.none (Maybe.map (errorBanner theme) maybeError)


errorBanner : Theme -> String -> Element msg
errorBanner theme message =
    Element.paragraph
        [ Background.color theme.dangerBg
        , Font.color theme.dangerFg
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        [ Element.text message ]



-- Buttons


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


submittingOrIdle : Bool -> SubmitState
submittingOrIdle isSubmitting =
    if isSubmitting then
        Submitting

    else
        Idle


type alias ButtonConfig msg =
    { tone : ButtonTone
    , width : ButtonWidth
    , label : String
    , onPress : msg
    , submitState : Maybe SubmitState
    , submittingLabel : Maybe String
    , trailing : Maybe (Element msg)
    }


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


bottomNavBar : Theme -> List (Element msg) -> Element msg
bottomNavBar theme items =
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 56)
        , Background.color theme.cardBg
        , Border.widthEach { top = 1, bottom = 0, left = 0, right = 0 }
        , Border.color theme.divider
        , Region.navigation

        -- Keep viewport positioning inline.
        -- elm-ui's generated position rules can override class-based CSS here.
        , Element.htmlAttribute (Html.Attributes.style "position" "fixed")
        , Element.htmlAttribute (Html.Attributes.style "right" "0")
        , Element.htmlAttribute (Html.Attributes.style "bottom" "0")
        , Element.htmlAttribute (Html.Attributes.style "left" "0")
        , Element.htmlAttribute (Html.Attributes.style "z-index" "10")
        ]
        items


bottomNavTab :
    Theme
    -> { icon : Icon, label : String, active : Bool, onPress : msg }
    -> Element msg
bottomNavTab theme config =
    let
        iconColor : Element.Color
        iconColor =
            if config.active then
                theme.brandBlue

            else
                theme.textMuted
    in
    Input.button
        [ Element.width (Element.fillPortion 1)
        , Element.height Element.fill
        , Element.paddingEach { top = 6, right = 0, bottom = 4, left = 0 }
        , Font.color
            iconColor
        , Border.widthEach
            { top =
                if config.active then
                    2

                else
                    0
            , bottom = 0
            , left = 0
            , right = 0
            }
        , Border.color theme.brandBlue
        ]
        { onPress = Just config.onPress
        , label =
            Element.column
                [ Element.centerX
                , Element.centerY
                , Element.spacing 2
                ]
                [ Element.el [ Element.centerX ]
                    (Icon.view
                        { icon = config.icon
                        , size = 22
                        , color = iconColor
                        }
                    )
                , Element.el
                    [ Element.centerX
                    , Font.size 12
                    ]
                    (Element.text config.label)
                ]
        }



-- Inputs


type alias InputConfig msg =
    { label : String
    , value : String
    , onChange : String -> msg
    }


input : Theme -> InputConfig msg -> Element msg
input theme config =
    textInput theme [] config


{-| Amount field: shows the decimal keypad on mobile and folds a locale comma
back to a period before the page ever sees the value.
-}
decimalInput : Theme -> InputConfig msg -> Element msg
decimalInput theme config =
    textInput theme
        [ inputMode "decimal" ]
        { config | onChange = config.onChange << Number.normalizeDecimalSeparator }


{-| Digits-only keypad for fields such as a barcode: no decimal separator. Passed
through `searchInput`'s `extraAttrs` so other search fields keep their keyboard.
-}
numericInputMode : Element.Attribute msg
numericInputMode =
    inputMode "numeric"


inputMode : String -> Element.Attribute msg
inputMode mode =
    Element.htmlAttribute (Html.Attributes.attribute "inputmode" mode)


textInput : Theme -> List (Element.Attribute msg) -> InputConfig msg -> Element msg
textInput theme extraAttrs config =
    Input.text
        ([ Border.rounded radiusControl
         , Background.color theme.inputFill
         , Element.padding 10
         , uiClass "ui-motion"
         ]
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
        { label : String
        , text : String
        , onChange : String -> msg
        , extraAttrs : List (Element.Attribute msg)
        }
    -> Element msg
searchInput theme config =
    Input.text
        ([ Border.rounded radiusControl
         , Background.color theme.inputFill
         , Element.padding space12
         , uiClass "ui-motion"
         ]
            ++ config.extraAttrs
        )
        { onChange = config.onChange
        , text = config.text
        , placeholder = Nothing
        , label = Input.labelAbove [ body, Font.medium ] (Element.text config.label)
        }


passwordInput : Theme -> InputConfig msg -> Element msg
passwordInput theme config =
    Input.currentPassword
        [ Border.rounded radiusControl
        , Background.color theme.inputFill
        , Element.padding 10
        , uiClass "ui-motion"
        ]
        { onChange = config.onChange
        , text = config.value
        , placeholder = Nothing
        , label = Input.labelAbove [] (fieldLabel theme config.label)
        , show = False
        }


fieldLabel : Theme -> String -> Element msg
fieldLabel theme label =
    Element.el
        [ caption
        , Font.medium
        , Font.color theme.textPrimary
        ]
        (Element.text label)


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
    Element.column
        [ Element.width Element.fill
        , Element.spacing space4
        ]
        [ fieldLabel theme config.label
        , Element.el
            [ Element.width Element.fill
            , Element.inFront
                (Element.el
                    [ Element.alignRight
                    , Element.centerY
                    , Element.paddingEach { top = 0, right = 12, bottom = 0, left = 0 }
                    , Font.color theme.textMuted
                    , body
                    ]
                    (Element.text config.suffix)
                )
            ]
            (Input.text
                [ Border.rounded radiusControl
                , Background.color theme.inputFill
                , Element.width Element.fill
                , Element.paddingEach { top = 10, right = 56, bottom = 10, left = 10 }
                , uiClass "ui-motion"
                , inputMode "decimal"
                ]
                { onChange = config.onChange << Number.normalizeDecimalSeparator
                , text = config.text
                , placeholder = Nothing
                , label = Input.labelHidden config.label
                }
            )
        ]



-- Display


modalOverlay :
    Theme
    ->
        { title : String
        , body : List (Element msg)
        , actions : Element msg
        , onBackgroundPress : Maybe msg
        }
    -> Element msg
modalOverlay theme config =
    let
        modalCard : Element msg
        modalCard =
            Element.el
                [ Element.centerX
                , Element.centerY
                , Element.width (Element.fill |> Element.maximum 480)
                , Element.padding 16
                , uiClass "ui-modal-card"
                ]
                (card theme
                    (sectionTitle theme config.title
                        :: config.body
                        ++ [ config.actions ]
                    )
                )
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.inFront modalCard
        ]
        (Input.button
            [ Element.width Element.fill
            , Element.height Element.fill
            , Background.color (Element.rgba255 0 0 0 0.28)
            , uiClass "ui-modal-backdrop"
            ]
            { onPress = config.onBackgroundPress
            , label = Element.none
            }
        )


scrimOverlay : Maybe msg -> Element msg
scrimOverlay onPress =
    Input.button
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color (Element.rgba255 0 0 0 0.28)
        ]
        { onPress = onPress
        , label = Element.none
        }


detailRow : Theme -> String -> Element msg -> Element msg
detailRow theme label value =
    Element.row
        [ Element.width Element.fill
        , Element.spacing space4
        , minWidthZero
        ]
        [ Element.el [ Font.color theme.textMedium, caption ]
            (Element.text (label ++ ":"))
        , Element.el [ Element.width Element.fill, minWidthZero ] value
        ]


badge : Theme -> String -> Element msg
badge theme label =
    Element.el
        [ Background.color theme.inputFill
        , Font.color theme.textPrimary
        , Border.rounded radiusPill
        , Element.paddingEach { top = 4, right = 8, bottom = 4, left = 8 }
        , caption
        , Font.medium
        ]
        (Element.text label)


menuCard :
    Theme
    -> { width : Int, children : List (Element msg) }
    -> Element msg
menuCard theme config =
    Element.column
        [ Element.alignRight
        , Element.moveDown 4
        , Element.width (Element.px config.width)
        , Element.padding space12
        , Element.spacing 10
        , Background.color theme.cardBg
        , Border.rounded radiusCard
        , cardShadow theme
        ]
        config.children


drawerPanel : Theme -> List (Element msg) -> Element msg
drawerPanel theme children =
    Element.column
        [ Element.width (Element.fill |> Element.maximum 320)
        , Element.height Element.fill
        , Element.paddingXY 16 9
        , Element.spacing space12
        , Background.color theme.cardBg
        , cardShadow theme
        , Region.navigation
        ]
        children


drawerItem :
    Theme
    -> { icon : Maybe Icon, label : String, selected : Bool, onPress : msg }
    -> Element msg
drawerItem theme config =
    let
        itemColor : Element.Color
        itemColor =
            if config.selected then
                theme.brandBlue

            else
                theme.textPrimary

        iconEl : Element msg
        iconEl =
            case config.icon of
                Just icon ->
                    Icon.view
                        { icon = icon
                        , size = 20
                        , color = itemColor
                        }

                Nothing ->
                    Element.none
    in
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY 16 14
        , Border.rounded radiusControl
        , Background.color
            (if config.selected then
                theme.drawerSelectionBg

             else
                theme.cardBg
            )
        , Font.color itemColor
        , Font.medium
        ]
        { onPress = Just config.onPress
        , label =
            Element.row
                [ Element.spacing 12
                , Element.centerY
                ]
                [ iconEl
                , Element.text config.label
                ]
        }


completionDropdown :
    Theme
    -> { height : Int, rows : List (Element msg) }
    -> Element msg
completionDropdown theme config =
    optionList theme
        { maxHeight = Just config.height
        , rows = config.rows
        }


optionList :
    Theme
    -> { maxHeight : Maybe Int, rows : List (Element msg) }
    -> Element msg
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
             , cardShadow theme
             ]
                ++ (case config.maxHeight of
                        Just height ->
                            [ Element.height (Element.px height)
                            , Element.scrollbarY
                            ]

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
    let
        itemColor : Element.Color
        itemColor =
            if config.selected then
                Element.rgb255 255 255 255

            else
                theme.textPrimary
    in
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY space12 10
        , Border.rounded radiusControl
        , Background.color
            (if config.selected then
                theme.brandBlue

             else
                theme.cardBg
            )
        , Font.color itemColor
        , uiClass "ui-motion ui-pressable"
        ]
        { onPress = Just config.onPress
        , label =
            Element.row [ Element.width Element.fill, Element.spacing space8, minWidthZero ]
                [ Element.el
                    [ Element.width Element.fill
                    , Font.medium
                    , minWidthZero
                    ]
                    (Element.text config.label)
                , Maybe.withDefault Element.none config.trailing
                ]
        }


suggestionList : Theme -> List (Element msg) -> Element msg
suggestionList theme items =
    optionList theme
        { maxHeight = Nothing
        , rows = items
        }


selectDropdown :
    Device
    -> Theme
    ->
        { label : String
        , selected : a
        , options : List ( a, String )
        , onChange : a -> msg
        , isOpen : Bool
        , onToggle : msg
        }
    -> Element msg
selectDropdown device theme config =
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
                [ Element.moveDown 4
                , Element.htmlAttribute (Html.Attributes.style "z-index" "20")
                ]
                (optionList theme
                    { maxHeight = Nothing
                    , rows = List.map renderOption config.options
                    }
                )

        triggerAnchor : List (Element.Attribute msg)
        triggerAnchor =
            if config.isOpen then
                [ Element.width Element.fill, Element.below optionsElement ]

            else
                [ Element.width Element.fill ]
    in
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        [ fieldLabel theme config.label
        , Element.el triggerAnchor
            (Input.button
                [ Element.width Element.fill
                , Border.rounded radiusControl
                , Background.color theme.inputFill
                , Element.padding space12
                , Border.width 1
                , Border.color theme.inputFill
                , uiClass "ui-motion"
                , hoverEffect device [ Border.color theme.brandBlue ]
                ]
                { onPress = Just config.onToggle
                , label =
                    Element.row [ Element.width Element.fill, Element.spacing space8 ]
                        [ Element.el
                            [ Element.width Element.fill
                            , body
                            , Font.color
                                (if selectedLabel == "" then
                                    theme.textMuted

                                 else
                                    theme.textPrimary
                                )
                            ]
                            (Element.text
                                (if selectedLabel == "" then
                                    "Select…"

                                 else
                                    selectedLabel
                                )
                            )
                        , Icon.view
                            { icon =
                                if config.isOpen then
                                    Icon.ChevronUp

                                else
                                    Icon.ChevronDown
                            , size = 20
                            , color = theme.textMuted
                            }
                        ]
                }
            )
        ]


skeletonLoading : Theme -> Element msg
skeletonLoading theme =
    Element.column [ Element.width Element.fill, Element.spacing space12 ]
        [ skeletonBar theme
        , skeletonBar theme
        , skeletonBar theme
        ]


skeletonBar : Theme -> Element msg
skeletonBar theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 16)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        ]
        Element.none


skeletonBarCustom : Theme -> { width : Element.Length, height : Int } -> Element msg
skeletonBarCustom theme config =
    Element.el
        [ Element.width config.width
        , Element.height (Element.px config.height)
        , Background.color theme.inputFill
        , Border.rounded radiusSmall
        , uiClass "ui-skeleton"
        ]
        Element.none


skeletonCircle : Theme -> Element msg
skeletonCircle theme =
    Element.el
        [ Element.width (Element.px 12)
        , Element.height (Element.px 12)
        , Background.color theme.inputFill
        , Border.rounded 999
        , uiClass "ui-skeleton"
        ]
        Element.none


skeletonInput : Theme -> Element msg
skeletonInput theme =
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


skeletonButton : Theme -> Element msg
skeletonButton theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 48)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , uiClass "ui-skeleton"
        ]
        Element.none


skeletonListRow : Theme -> Element msg
skeletonListRow theme =
    Element.wrappedRow
        [ Element.width Element.fill
        , Element.padding space16
        , Element.spacing space12
        ]
        [ Element.el
            [ Element.width (Element.px 12)
            , Element.alignTop
            , Element.paddingEach { top = space2, right = 0, bottom = 0, left = 0 }
            ]
            (skeletonCircle theme)
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


skeletonCard : Theme -> { rows : Int } -> Element msg
skeletonCard theme config =
    card theme
        (List.map (\_ -> skeletonBar theme)
            (List.range 1 (max 1 config.rows))
        )


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
        , onClick : Maybe msg
        }
    -> Element msg
chip theme config =
    Element.html (chipHtml theme config)


removableChip :
    Device
    -> Theme
    -> { label : String, onRemove : msg }
    -> Element msg
removableChip device theme config =
    let
        removeSize : Int
        removeSize =
            28
    in
    Element.row
        [ Background.color (chipBackground theme False)
        , Font.color (chipForeground theme False)
        , Border.rounded radiusPill
        , Element.paddingEach { top = 4, right = 4, bottom = 4, left = 10 }
        , Element.spacing space8
        , caption
        , Font.medium
        ]
        [ Element.text config.label
        , Input.button
            [ Element.width (Element.px removeSize)
            , Element.height (Element.px removeSize)
            , Background.color theme.cardBg
            , Font.color theme.dangerFg
            , Font.center
            , Border.rounded radiusPill
            , Border.width 1
            , Border.color theme.dangerFg
            , hoverEffect device
                [ Background.color theme.dangerSolid
                , Font.color (Element.rgb255 255 255 255)
                , Border.color theme.dangerSolid
                ]
            ]
            { onPress = Just config.onRemove
            , label =
                Element.el [ Element.centerX, Element.centerY ]
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
        , onClick : Maybe msg
        }
    -> Html msg
chipHtml _ config =
    let
        chipClass : String
        chipClass =
            "ui-chip ui-motion ui-pressable"
                ++ (if config.selected then
                        " ui-chip-selected"

                    else
                        ""
                   )

        baseStyles : List (Html.Attribute msg)
        baseStyles =
            [ Html.Attributes.class chipClass ]
    in
    case config.onClick of
        Just msg ->
            Html.button
                [ Html.Attributes.class (chipClass ++ " ui-chip-button ui-hover-brighten")
                , Html.Events.onClick msg
                ]
                [ Html.text config.label ]

        Nothing ->
            Html.span
                baseStyles
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
                        chipHtml theme { label = c, selected = False, onClick = Nothing }
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
    Element.el
        [ Background.color config.bg
        , Font.color config.fg
        , Border.rounded radiusPill
        , Element.paddingEach { top = 4, right = 10, bottom = 4, left = 10 }
        , caption
        , Font.medium
        ]
        (Element.text config.label)


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


linearProgress :
    Theme
    ->
        { value : Float
        , max : Float
        , color : Element.Color
        }
    -> Element msg
linearProgress theme config =
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
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 10)
        , Background.color theme.inputFill
        , Border.rounded radiusPill
        , Element.clip
        ]
        [ Element.el
            [ Element.width (Element.fillPortion filled)
            , Element.height Element.fill
            , Background.color config.color
            , Border.rounded radiusPill
            ]
            Element.none
        , Element.el [ Element.width (Element.fillPortion remaining) ] Element.none
        ]


toggleSwitch : Theme -> { isActive : Bool, onToggle : msg } -> Element msg
toggleSwitch theme config =
    Input.button
        [ Element.width (Element.px 44)
        , Element.height (Element.px 24)
        , Border.rounded radiusPill
        , Background.color theme.inputFill
        , Element.padding space2
        , uiClass
            ("ui-toggle-track ui-motion ui-pressable"
                ++ (if config.isActive then
                        " ui-toggle-on"

                    else
                        ""
                   )
            )
        ]
        { onPress = Just config.onToggle
        , label =
            Element.el
                [ Element.width Element.fill
                , Element.height Element.fill
                ]
                (Element.html (Html.span [ Html.Attributes.class "ui-toggle-thumb" ] []))
        }


accentDot : Element.Color -> Element msg
accentDot color =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        , Background.color color
        , Border.rounded radiusHairline
        ]
        Element.none


hairline : Theme -> Element msg
hairline theme =
    Element.el
        [ Element.width Element.fill
        , Element.height (Element.px 1)
        , Background.color theme.divider
        ]
        Element.none


dotSeparated : List (Maybe String) -> String
dotSeparated strings =
    strings |> List.filterMap identity |> String.join " ⋅ "
