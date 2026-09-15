module Ui exposing
    ( PageHeaderSubtitle(..)
    , accentDot
    , card
    , detailRow
    , dotSeparated
    , emptyState
    , errorBanner
    , formSection
    , hairline
    , heroCard
    , infoBanner
    , isSmall
    , layout
    , linearProgress
    , listCard
    , listRow
    , loading
    , maybeErrorBanner
    , modalOverlay
    , pageContainer
    , pageHeader
    , section
    )

import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui.DesignTokens
    exposing
        ( radiusCard
        , radiusControl
        , radiusHairline
        , radiusPill
        , space12
        , space16
        , space2
        , space20
        , space4
        , space8
        )
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


infoBanner : Theme -> String -> Element msg
infoBanner theme message =
    Element.paragraph
        [ Background.color theme.brandBlueSoft
        , Font.color theme.textPrimary
        , Border.rounded radiusControl
        , Element.padding space12
        , Element.width Element.fill
        ]
        [ Element.text message ]



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
