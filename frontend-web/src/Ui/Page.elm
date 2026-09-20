module Ui.Page exposing
    ( PageHeaderSubtitle(..)
    , pageContainer
    , pageHeader
    )

import Element exposing (Device, Element)
import Element.Font as Font
import Ui.Common exposing (minWidthZero)
import Ui.DesignTokens exposing (space16, space2, space4, space8)
import Ui.Theme exposing (Theme)
import Ui.Typography exposing (body, mutedBody)


type PageHeaderSubtitle
    = SubtitleText String
    | SubtitleMeta { items : List String, separator : String }
    | SubtitleMetaLines { lines : List (List String), separator : String }


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
        , Element.spacing space16
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
