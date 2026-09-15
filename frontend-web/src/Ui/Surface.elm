module Ui.Surface exposing
    ( accentDot
    , card
    , detailRow
    , formSection
    , hairline
    , heroCard
    , listCard
    , listRow
    , section
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Ui.Common exposing (minWidthZero, uiClass)
import Ui.DesignTokens
    exposing
        ( radiusCard
        , radiusHairline
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
        ( caption
        , mutedParagraph
        , subsectionTitle
        )


cardShadow : Theme -> Element.Attribute msg
cardShadow _ =
    uiClass "ui-card-shadow"


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
            , Element.paddingEach
                { top = 0
                , right = space20
                , bottom = space20
                , left = space20
                }
            , Element.spacing space12
            ]
            config.body
        ]


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
        , Element.paddingEach
            { top = space2
            , right = 0
            , bottom = 0
            , left = 0
            }
        , Element.alignTop
        ]
        (case leading of
            first :: _ ->
                first

            [] ->
                Element.none
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
