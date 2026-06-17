module Ui exposing
    ( BottomActionTone(..)
    , InputConfig
    , SubmitButtonConfig
    , SubmitState(..)
    , accentDot
    , accentPink
    , accentSoftGreen
    , accentYellow
    , badge
    , body
    , bottomActionButtons
    , bottomNavBar
    , bottomNavTab
    , button
    , caption
    , card
    , chip
    , chipBackground
    , chips
    , coloredPill
    , completionDropdown
    , completionRow
    , dangerIconButton
    , detailRow
    , disabledIconButton
    , dotSeparated
    , drawerItem
    , drawerPanel
    , emptyState
    , errorBanner
    , fieldLabel
    , formSection
    , fullWidthDangerButton
    , fullWidthGhostButton
    , ghostButton
    , hairline
    , heroCard
    , iconButton
    , input
    , inputWithSuffix
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
    , menuCard
    , modalOverlay
    , mutedBody
    , mutedCaption
    , mutedParagraph
    , pageContainer
    , pageHeader
    , pageTitle
    , passwordInput
    , primarySubmitButton
    , radiusPill
    , radiusTight
    , removableChip
    , scrimOverlay
    , searchInput
    , section
    , sectionTitle
    , selectDropdown
    , skeletonBar
    , skeletonLoading
    , space12
    , space16
    , space2
    , space24
    , space4
    , space8
    , statBlock
    , statBlockGroup
    , statusBadge
    , submittingOrIdle
    , subsectionTitle
    , suggestionList
    , tableHeader
    , themeCssVariables
    , toCssColor
    , toggleSwitch
    , truncatedHeader
    , truncatedListItemTitle
    , truncatedText
    , wrappedListItemTitle
    )

import Data.Nutrition
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html exposing (Html)
import Html.Attributes
import Html.Events
import Lib.ListExtra as ListExtra
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme exposing (Theme)



-- Accent palette for non-semantic decorative use


accentPink : Element.Color
accentPink =
    Element.rgb255 255 138 170


accentYellow : Element.Color
accentYellow =
    Element.rgb255 255 210 80


accentSoftGreen : Element.Color
accentSoftGreen =
    Element.rgb255 200 235 200



-- Spacing scale


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



-- Border radius scale


radiusHairline : Int
radiusHairline =
    2


radiusTight : Int
radiusTight =
    4


radiusSmall : Int
radiusSmall =
    8


radiusControl : Int
radiusControl =
    12


radiusCard : Int
radiusCard =
    20


radiusHero : Int
radiusHero =
    24


radiusPill : Int
radiusPill =
    999



-- Typography


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


pageTitle : Theme -> Device -> String -> Element msg
pageTitle theme device text =
    Element.el
        [ onPhone device (Font.size 24) sizePageTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 1
        ]
        (Element.text text)


sectionTitle : Theme -> Device -> String -> Element msg
sectionTitle theme device text =
    Element.el
        [ onPhone device (Font.size 18) sizeSectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 2
        ]
        (Element.text text)


subsectionTitle : Theme -> Device -> String -> Element msg
subsectionTitle theme device text =
    Element.el
        [ onPhone device (Font.size 15) sizeSubsectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 3
        ]
        (Element.text text)


listItemTitle : Theme -> Element msg -> Element msg
listItemTitle theme child =
    Element.el
        [ body
        , Font.bold
        , Font.color theme.textPrimary
        ]
        child


truncatedListItemTitle : Theme -> Device -> String -> Element msg
truncatedListItemTitle theme _ name =
    Element.el
        [ Element.width Element.fill ]
        (listItemTitle theme
            (Element.el
                [ Element.width Element.fill
                , Element.clip
                , uiClass "ui-text-ellipsis"
                ]
                (Element.text name)
            )
        )


wrappedListItemTitle : Theme -> String -> Element msg
wrappedListItemTitle theme name =
    listItemTitle theme
        (Element.paragraph
            [ Element.width Element.fill
            , minWidthZero
            ]
            [ Element.text name ]
        )


mutedCaption : Theme -> String -> Element msg
mutedCaption theme text =
    Element.el
        [ caption
        , Font.color theme.textMuted
        ]
        (Element.text text)


tableHeader : Theme -> String -> Element msg
tableHeader theme text =
    Element.el
        [ body
        , Font.bold
        , Font.color theme.textMuted
        ]
        (Element.text text)



-- Surfaces & layout


cardShadow : Theme -> Element.Attribute msg
cardShadow _ =
    uiClass "ui-card-shadow"


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


isSmall : Device -> Bool
isSmall device =
    device.class == Element.Phone


onPhone : Device -> a -> a -> a
onPhone device phoneValue desktopValue =
    if isSmall device then
        phoneValue

    else
        desktopValue


hoverEffect : Device -> List Element.Decoration -> Element.Attribute msg
hoverEffect device attrs =
    if isSmall device then
        Element.mouseOver []

    else
        Element.mouseOver attrs


uiClass : String -> Element.Attribute msg
uiClass className =
    Element.htmlAttribute (Html.Attributes.class className)


minWidthZero : Element.Attribute msg
minWidthZero =
    Element.htmlAttribute (Html.Attributes.style "min-width" "0")


truncatedText : Device -> String -> Element msg
truncatedText _ string =
    Element.el
        [ Element.width Element.fill
        , Element.clip
        , uiClass "ui-text-ellipsis"
        ]
        (Element.text string)


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
        , subtitle : Maybe String
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
                            Just text ->
                                [ mutedBody theme text ]

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


macroDotGhost : Element msg
macroDotGhost =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        ]
        Element.none


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


formSection : Theme -> Device -> String -> List (Element msg) -> Element msg
formSection theme device title content =
    section theme
        { header = Just (subsectionTitle theme device title)
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
    Element.el
        [ Background.color theme.dangerBg
        , Font.color theme.dangerFg
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        (Element.text message)



-- Buttons


button : Device -> Theme -> String -> msg -> Element msg
button device theme label msg =
    Input.button
        [ Background.color theme.brandBlue
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded radiusPill
        , Element.paddingEach { top = 14, right = 18, bottom = 14, left = 18 }
        , Font.medium
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device [ Background.color theme.brandBluePressed ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


type SubmitState
    = Idle
    | Submitting
    | Disabled


type BottomActionTone
    = PrimaryAction
    | SecondaryAction
    | DangerAction


submittingOrIdle : Bool -> SubmitState
submittingOrIdle isSubmitting =
    if isSubmitting then
        Submitting

    else
        Idle


type alias SubmitButtonConfig msg =
    { state : SubmitState
    , idleLabel : String
    , submittingLabel : String
    , onPress : msg
    }


primarySubmitButton : Device -> Theme -> SubmitButtonConfig msg -> Element msg
primarySubmitButton device theme config =
    let
        label : String
        label =
            case config.state of
                Submitting ->
                    config.submittingLabel

                _ ->
                    config.idleLabel

        active : Bool
        active =
            config.state == Idle
    in
    Input.button
        [ Background.color
            (if active then
                theme.brandBlue

             else
                theme.brandBlueDisabled
            )
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded radiusPill
        , Element.width Element.fill
        , onPhone device (Element.height (Element.px 56)) (Element.padding 0)
        , Element.paddingEach { top = 14, right = 20, bottom = 14, left = 20 }
        , Font.medium
        , Font.center
        , uiClass "ui-motion ui-pressable"
        , if active then
            hoverEffect device [ Background.color theme.brandBluePressed ]

          else
            hoverEffect device []
        ]
        { onPress =
            if active then
                Just config.onPress

            else
                Nothing
        , label = Element.text label
        }


bottomActionButtons :
    Device
    -> Theme
    -> List { label : String, onPress : msg, tone : BottomActionTone }
    -> Element msg
bottomActionButtons device theme buttons =
    let
        buttonView : { label : String, onPress : msg, tone : BottomActionTone } -> Element msg
        buttonView config =
            Element.el [ Element.width Element.fill ]
                (case config.tone of
                    PrimaryAction ->
                        primaryActionButton device theme config.label config.onPress

                    SecondaryAction ->
                        fullWidthGhostButton device theme config.label config.onPress

                    DangerAction ->
                        fullWidthDangerButton device theme config.label config.onPress
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


primaryActionButton : Device -> Theme -> String -> msg -> Element msg
primaryActionButton device theme label msg =
    Input.button
        [ Background.color theme.brandBlue
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded radiusPill
        , Element.width Element.fill
        , onPhone device (Element.height (Element.px 56)) (Element.padding 0)
        , Element.paddingEach { top = 14, right = 20, bottom = 14, left = 20 }
        , Font.medium
        , Font.center
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device [ Background.color theme.brandBluePressed ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


fullWidthDangerButton : Device -> Theme -> String -> msg -> Element msg
fullWidthDangerButton device theme label msg =
    Input.button
        [ Background.color theme.dangerSolid
        , Font.color (Element.rgb255 255 255 255)
        , Border.rounded radiusPill
        , Element.width Element.fill
        , onPhone device (Element.height (Element.px 56)) (Element.padding 0)
        , Element.paddingEach { top = 14, right = 20, bottom = 14, left = 20 }
        , Font.medium
        , Font.center
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device [ Background.color theme.dangerFg ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


ghostButton : Device -> Theme -> String -> msg -> Element msg
ghostButton device theme label msg =
    Input.button
        [ Border.rounded radiusPill
        , Element.paddingEach { top = 10, right = 16, bottom = 10, left = 16 }
        , Font.color theme.brandBlue
        , Font.medium
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device [ Background.color theme.brandBlueSoft ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


fullWidthGhostButton : Device -> Theme -> String -> msg -> Element msg
fullWidthGhostButton device theme label msg =
    Input.button
        [ Element.width Element.fill
        , Element.paddingEach { top = 14, right = 16, bottom = 14, left = 16 }
        , Border.rounded radiusPill
        , Font.color theme.brandBlue
        , Font.medium
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device [ Background.color theme.brandBlueSoft ]
        ]
        { onPress = Just msg
        , label = Element.text label
        }


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
                    , Font.size 11
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
    Input.text
        [ Border.rounded radiusControl
        , Background.color theme.inputFill
        , Element.padding 10
        , uiClass "ui-motion"
        ]
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


inputWithSuffix :
    Theme
    ->
        { label : String
        , text : String
        , suffix : String
        , onChange : String -> msg
        }
    -> Element msg
inputWithSuffix theme config =
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
                ]
                { onChange = config.onChange
                , text = config.text
                , placeholder = Nothing
                , label = Input.labelHidden config.label
                }
            )
        ]



-- Display


mutedBody : Theme -> String -> Element msg
mutedBody theme text =
    Element.el
        [ Font.color theme.textMuted
        , body
        ]
        (Element.text text)


mutedParagraph : Theme -> String -> Element msg
mutedParagraph theme text =
    Element.paragraph
        [ Font.color theme.textMuted
        , body
        ]
        [ Element.text text ]


modalOverlay :
    Theme
    -> Device
    ->
        { title : String
        , body : List (Element msg)
        , actions : Element msg
        , onBackgroundPress : Maybe msg
        }
    -> Element msg
modalOverlay theme device config =
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
                    (sectionTitle theme device config.title
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
    Element.row [ Element.spacing space4 ]
        [ Element.el [ Font.color theme.textMedium, caption ]
            (Element.text (label ++ ":"))
        , value
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
    -> { label : String, selected : Bool, onPress : msg }
    -> Element msg
drawerItem theme config =
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
        , Font.color
            (if config.selected then
                theme.brandBlue

             else
                theme.textPrimary
            )
        , Font.medium
        ]
        { onPress = Just config.onPress
        , label = Element.text config.label
        }


completionDropdown :
    Theme
    -> { height : Int, rows : List (Element msg) }
    -> Element msg
completionDropdown theme config =
    if List.isEmpty config.rows then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.height (Element.px config.height)
            , Element.scrollbarY
            , Element.spacing space2
            , Element.padding space4
            , Border.rounded radiusControl
            , Background.color theme.cardBg
            , cardShadow theme
            ]
            config.rows


completionRow :
    Device
    ->
        { label : String
        , trailing : Maybe (Element msg)
        , onPress : msg
        }
    -> Element msg
completionRow device config =
    Input.button
        [ Element.width Element.fill
        , if isSmall device then
            Element.padding space12

          else
            Element.paddingXY 12 10
        , Border.rounded radiusPill
        ]
        { onPress = Just config.onPress
        , label =
            Element.row [ Element.width Element.fill, Element.spacing space8 ]
                [ Element.el
                    [ Element.width Element.fill, Font.medium ]
                    (Element.text config.label)
                , Maybe.withDefault Element.none config.trailing
                ]
        }


suggestionList : Theme -> List (Element msg) -> Element msg
suggestionList theme items =
    if List.isEmpty items then
        Element.none

    else
        Element.column
            [ Element.width Element.fill
            , Element.spacing space4
            , Border.rounded radiusControl
            , Background.color theme.cardBg
            , Border.width 1
            , Border.color theme.divider
            , Element.padding space8
            ]
            items


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
            Input.button
                [ Element.width Element.fill
                , Element.paddingXY space16 space12
                , Background.color
                    (if isSelected val then
                        theme.brandBlue

                     else
                        theme.cardBg
                    )
                , Font.color
                    (if isSelected val then
                        Element.rgb255 255 255 255

                     else
                        theme.textPrimary
                    )
                ]
                { onPress = Just (config.onChange val)
                , label = Element.text lbl
                }

        optionsElement : Element msg
        optionsElement =
            Element.column
                [ Element.width Element.fill
                , Border.rounded radiusControl
                , Background.color theme.cardBg
                , cardShadow theme
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


macroColor : Theme -> Data.Nutrition.Macro -> Element.Color
macroColor theme m =
    case m of
        Data.Nutrition.Protein ->
            theme.proteinAccent

        Data.Nutrition.Carbs ->
            theme.carbsAccent

        Data.Nutrition.Fat ->
            theme.fatAccent


macroBar :
    Theme
    ->
        { label : String
        , value : Float
        , unit : String
        , color : Element.Color
        , max : Float
        }
    -> Element msg
macroBar theme config =
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
            [ Element.el
                [ Font.bold, body, Font.color theme.textPrimary ]
                (Element.text config.label)
            , Element.el
                [ body
                , Font.color theme.textMuted
                , Element.alignRight
                ]
                (Element.text (String.fromInt (round config.value) ++ " " ++ config.unit))
            ]
        , Element.row
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


truncatedHeader : Theme -> Device -> String -> Element msg
truncatedHeader theme _ heading =
    Element.paragraph
        [ sizeSectionTitle
        , Font.bold
        , Font.color theme.textPrimary
        , Region.heading 2
        , Element.width Element.fill
        , minWidthZero
        ]
        [ Element.text heading ]


iconButton : Device -> Theme -> { icon : Icon, title : String, onPress : msg } -> Element msg
iconButton device theme config =
    Input.button
        [ Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Background.color theme.cardBg
        , Font.color theme.textPrimary
        , Font.center
        , Border.rounded radiusPill
        , Border.width 1
        , Border.color theme.divider
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device
            [ Background.color theme.brandBlueSoft
            , Border.color theme.brandBlue
            ]
        , Element.htmlAttribute (Html.Attributes.title config.title)
        ]
        { onPress = Just config.onPress
        , label =
            Element.el [ Element.centerX, Element.centerY ]
                (Icon.view
                    { icon = config.icon
                    , size = 22
                    , color = theme.textPrimary
                    }
                )
        }


dangerIconButton :
    Device
    -> Theme
    -> { icon : Icon, title : String, onPress : msg }
    -> Element msg
dangerIconButton device theme config =
    let
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
        , Background.color theme.cardBg
        , Font.color theme.dangerFg
        , Font.center
        , Border.rounded radiusPill
        , Border.width 1
        , Border.color theme.dangerFg
        , uiClass "ui-motion ui-pressable"
        , hoverEffect device
            [ Background.color theme.dangerSolid
            , Font.color (Element.rgb255 255 255 255)
            , Border.color theme.dangerSolid
            ]
        , Element.htmlAttribute (Html.Attributes.title config.title)
        ]
        { onPress = Just config.onPress
        , label =
            Element.el [ Element.centerX, Element.centerY ]
                (Icon.view
                    { icon = config.icon
                    , size = iconSize
                    , color = theme.dangerFg
                    }
                )
        }


disabledIconButton : Theme -> { icon : Icon } -> Element msg
disabledIconButton theme config =
    Input.button
        [ Element.width (Element.px 40)
        , Element.height (Element.px 40)
        , Background.color theme.inputFill
        , Font.color theme.textMuted
        , Font.center
        , Border.rounded radiusPill
        ]
        { onPress = Nothing
        , label =
            Element.el [ Element.centerX, Element.centerY ]
                (Icon.view
                    { icon = config.icon
                    , size = 22
                    , color = theme.textMuted
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
            if isSmall device then
                28

            else
                18
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


themeCssVariables : Theme -> String
themeCssVariables theme =
    String.join "; "
        [ "--ui-page-bg: " ++ toCssColor theme.pageBg
        , "--ui-card-bg: " ++ toCssColor theme.cardBg
        , "--ui-text-primary: " ++ toCssColor theme.textPrimary
        , "--ui-text-muted: " ++ toCssColor theme.textMuted
        , "--ui-text-medium: " ++ toCssColor theme.textMedium
        , "--ui-divider: " ++ toCssColor theme.divider
        , "--ui-input-fill: " ++ toCssColor theme.inputFill
        , "--ui-brand-blue: " ++ toCssColor theme.brandBlue
        , "--ui-brand-blue-pressed: " ++ toCssColor theme.brandBluePressed
        , "--ui-brand-blue-soft: " ++ toCssColor theme.brandBlueSoft
        , "--ui-brand-blue-disabled: " ++ toCssColor theme.brandBlueDisabled
        , "--ui-danger-bg: " ++ toCssColor theme.dangerBg
        , "--ui-danger-fg: " ++ toCssColor theme.dangerFg
        , "--ui-danger-solid: " ++ toCssColor theme.dangerSolid
        , "--ui-drawer-selection-bg: " ++ toCssColor theme.drawerSelectionBg
        , "--ui-status-green: " ++ toCssColor theme.statusGreen
        , "--ui-status-red: " ++ toCssColor theme.statusRed
        , "--ui-status-active-bg: " ++ toCssColor theme.statusActiveBg
        , "--ui-status-disabled-bg: " ++ toCssColor theme.statusDisabledBg
        , "--ui-card-shadow: " ++ theme.cardShadow
        , "--ui-chip-bg: " ++ toCssColor theme.chipBg
        , "--ui-chip-border: " ++ toCssColor theme.chipBorder
        , "--ui-chip-fg: " ++ toCssColor theme.textPrimary
        , "--ui-chip-selected-bg: " ++ toCssColor theme.chipSelectedBg
        , "--ui-chip-selected-fg: " ++ toCssColor theme.chipSelectedFg
        , "--ui-focus-ring: " ++ toCssColor theme.focusRing
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
        , Border.rounded radiusHero
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
        , Background.color
            (if config.isActive then
                theme.brandBlue

             else
                theme.inputFill
            )
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
