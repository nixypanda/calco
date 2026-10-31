module Ui.Surface exposing
    ( PanelSection
    , accentDotLabeled
    , card
    , cardFill
    , detailRow
    , formSection
    , hairline
    , heroCard
    , listRow
    , panel
    , section
    , sectionHeader
    , staticRow
    )

import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html.Attributes
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language)
import Ui.Common exposing (minWidthZero, toCssColor, uiClass)
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
import Ui.Theme exposing (Mode(..), Theme)
import Ui.Typography
    exposing
        ( caption
        , subsectionTitle
        )


cardShadow : Theme -> Element.Attribute msg
cardShadow _ =
    uiClass "ui-card-shadow"


surfaceShell : Theme -> List (Element msg) -> Element msg
surfaceShell theme =
    surfaceShellWith [] theme


surfaceShellWith : List (Element.Attribute msg) -> Theme -> List (Element msg) -> Element msg
surfaceShellWith extraAttrs theme children =
    Element.column
        ([ Element.width Element.fill
         , Background.color theme.cardSurfaceBg
         , Border.rounded radiusCard
         , cardShadow theme
         , uiClass "ui-surface"
         ]
            ++ extraAttrs
        )
        children


card : Theme -> List (Element msg) -> Element msg
card theme children =
    surfaceShell theme
        [ Element.column
            [ Element.width Element.fill, Element.padding space20, Element.spacing space12 ]
            children
        ]


{-| A card that stretches to the height its parent offers and centers its
children vertically. Use for a whole area that carries a single empty or
placeholder message.
-}
cardFill : Theme -> List (Element msg) -> Element msg
cardFill theme children =
    surfaceShellWith [ Element.height (Element.fill |> Element.minimum 240) ]
        theme
        [ Element.el
            [ Element.width Element.fill, Element.height Element.fill ]
            (Element.column
                [ Element.centerX
                , Element.centerY
                , Element.width (Element.fill |> Element.maximum 420)
                , Element.padding space20
                , Element.spacing space12
                ]
                children
            )
        ]


heroCard :
    Theme
    ->
        { header : Element msg
        , body : List (Element msg)
        , mediaHeader :
            Maybe
                { height : Int
                , backgroundAttrs : List (Element.Attribute msg)
                , fade : Bool
                , contentPadding : { top : Int, right : Int, bottom : Int, left : Int }
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
                            ++ (if media.fade then
                                    [ Element.inFront (headerFade theme) ]

                                else
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
    surfaceShell theme
        [ headerElement
        , Element.column
            [ Element.width Element.fill
            , Element.paddingEach { top = 0, right = space20, bottom = space20, left = space20 }
            , Element.spacing space12
            ]
            config.body
        ]


{-| Media header scrim: fades the background image into the card surface so
overlaid content stays legible. Mode-aware, with the raw gradient stops kept
here rather than in page modules.
-}
headerFade : Theme -> Element msg
headerFade theme =
    let
        gradient : String
        gradient =
            case theme.mode of
                Light ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(255,255,255,0) 0%, "
                        ++ "rgba(255,255,255,0) 25%, "
                        ++ "rgba(255,255,255,0.48) 85%, "
                        ++ toCssColor theme.cardSurfaceBg
                        ++ " 100%)"

                Dark ->
                    "linear-gradient(to bottom, "
                        ++ "rgba(0,0,0,0.25) 0%, "
                        ++ "rgba(0,0,0,0.55) 45%, "
                        ++ "rgba(0,0,0,0.85) 75%, "
                        ++ toCssColor theme.cardSurfaceBg
                        ++ " 100%)"
    in
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , Element.htmlAttribute (Html.Attributes.style "background-image" gradient)
        ]
        Element.none


{-| One sub-block inside a `panel`: an optional plain-text title followed by
content. The title is intentionally unbanded so the panel's own header stays the
only tinted surface.
-}
type alias PanelSection msg =
    { title : Maybe (Element msg), body : List (Element msg) }


{-| A titled region that gathers several sub-blocks under one surface.

Use this instead of stacking several `section` cards or leaving several `card`
blocks untitled: the panel gives the group one header band, and its sections are
separated by hairlines so the reader sees one object with parts.

-}
panel :
    Theme
    ->
        { header : Maybe (Element msg)
        , sections : List (PanelSection msg)
        , footer : Maybe (Element msg)
        }
    -> Element msg
panel theme config =
    let
        sectionChildren : List (Element msg)
        sectionChildren =
            config.sections
                |> List.indexedMap
                    (\index sectionConfig ->
                        (if index == 0 then
                            []

                         else
                            [ hairline theme ]
                        )
                            ++ (sectionConfig.title
                                    |> Maybe.map List.singleton
                                    |> Maybe.withDefault []
                               )
                            ++ sectionConfig.body
                    )
                |> List.concat

        bodySlot : List (Element msg)
        bodySlot =
            sectionChildren
                ++ (config.footer
                        |> Maybe.map (\footerEl -> [ hairline theme, footerEl ])
                        |> Maybe.withDefault []
                   )

        bodyRegion : List (Element msg)
        bodyRegion =
            if List.isEmpty bodySlot then
                []

            else
                [ Element.column
                    [ Element.width Element.fill, Element.padding space20, Element.spacing space12 ]
                    bodySlot
                ]

        headerRounding : { bottomLeft : Int, bottomRight : Int, topLeft : Int, topRight : Int }
        headerRounding =
            if List.isEmpty bodyRegion then
                { topLeft = radiusCard
                , topRight = radiusCard
                , bottomLeft = radiusCard
                , bottomRight = radiusCard
                }

            else
                { topLeft = radiusCard, topRight = radiusCard, bottomLeft = 0, bottomRight = 0 }

        headerBand : List (Element msg)
        headerBand =
            case config.header of
                Just el ->
                    Element.column
                        [ Element.width Element.fill
                        , Background.color theme.cardHeaderBg
                        , Border.roundEach headerRounding
                        , Element.padding space20
                        , Element.spacing space12
                        ]
                        [ el ]
                        :: (if List.isEmpty bodyRegion then
                                []

                            else
                                [ hairline theme ]
                           )

                Nothing ->
                    []
    in
    surfaceShell theme (headerBand ++ bodyRegion)


{-| A single titled block on its own surface. Equivalent to a `panel` with one
untitled section, kept as the common case for one-block-per-page layouts.
-}
section :
    Theme
    ->
        { header : Maybe (Element msg)
        , body : List (Element msg)
        , footer : Maybe (Element msg)
        }
    -> Element msg
section theme config =
    panel theme
        { header = config.header
        , sections =
            if List.isEmpty config.body then
                []

            else
                [ { title = Nothing, body = config.body } ]
        , footer = config.footer
        }


sectionHeader :
    { title : Element msg
    , description : Maybe (Element msg)
    , trailing : Maybe (Element msg)
    }
    -> Element msg
sectionHeader config =
    Element.column [ Element.width Element.fill, Element.spacing space4 ]
        (Element.row
            [ Element.width Element.fill, Element.spacing space12 ]
            (Element.el [ Element.width Element.fill ] config.title
                :: (config.trailing
                        |> Maybe.map List.singleton
                        |> Maybe.withDefault []
                   )
            )
            :: (config.description |> Maybe.map List.singleton |> Maybe.withDefault [])
        )


formSection : Theme -> String -> List (Element msg) -> Element msg
formSection theme title content =
    section theme { header = Just (subsectionTitle theme title), body = content, footer = Nothing }


listRow :
    { onSelect : msg
    , leading : List (Element msg)
    , title : Element msg
    , subtitle : List (Element msg)
    , trailing : List (Element msg)
    }
    -> Element msg
listRow config =
    Element.wrappedRow listRowAttrs
        [ Input.button
            [ Element.width Element.fill, uiClass "ui-motion ui-pressable" ]
            { onPress = Just config.onSelect
            , label =
                Element.row listRowLabelAttrs
                    [ listRowLeading config.leading
                    , listRowText config.title config.subtitle
                    ]
            }
        , listRowTrailing config.trailing
        ]


{-| A non-selectable companion to `listRow` for rows whose own actions live in
the trailing slot, such as API keys with a revoke button.
-}
staticRow :
    { leading : List (Element msg)
    , title : Element msg
    , subtitle : List (Element msg)
    , trailing : List (Element msg)
    }
    -> Element msg
staticRow config =
    Element.wrappedRow listRowAttrs
        [ Element.row listRowLabelAttrs
            [ listRowLeading config.leading
            , listRowText config.title config.subtitle
            ]
        , listRowTrailing config.trailing
        ]


listRowAttrs : List (Element.Attribute msg)
listRowAttrs =
    [ Element.width Element.fill, Element.padding space16, Element.spacing space12 ]


listRowLabelAttrs : List (Element.Attribute msg)
listRowLabelAttrs =
    [ Element.width Element.fill, Element.spacing space12, minWidthZero ]


listRowText : Element msg -> List (Element msg) -> Element msg
listRowText title subtitle =
    Element.column
        [ Element.width Element.fill
        , Element.spacing space4
        , Element.alignTop
        , minWidthZero
        ]
        (title :: subtitle)


listRowTrailing : List (Element msg) -> Element msg
listRowTrailing trailing =
    if List.isEmpty trailing then
        Element.none

    else
        Element.row [ Element.padding space8, Element.spacing space12, Element.alignTop ] trailing


listRowLeading : List (Element msg) -> Element msg
listRowLeading leading =
    Element.el
        [ Element.width (Element.px 12)
        , Element.paddingEach
            { top = space2, right = 0, bottom = 0, left = 0 }
        , Element.alignTop
        ]
        (case leading of
            first :: _ ->
                first

            [] ->
                Element.none
        )


detailRow : Theme -> Language -> String -> Element msg -> Element msg
detailRow theme language label value =
    Element.row [ Element.width Element.fill, Element.spacing space4, minWidthZero ]
        [ Element.el [ Font.color theme.textMedium, caption ]
            (Element.text (I18n.t language (TidUiDetailRowLabelSuffix label)))
        , Element.el [ Element.width Element.fill, minWidthZero ] value
        ]


{-| Compact color bar that stands in for a macro. It carries an accessible
label so the meaning is not conveyed by color alone.
-}
accentDotLabeled : { color : Element.Color, label : String } -> Element msg
accentDotLabeled config =
    Element.el
        [ Element.width (Element.px 4)
        , Element.height (Element.px 24)
        , Background.color config.color
        , Border.rounded radiusHairline
        , Element.htmlAttribute (Html.Attributes.attribute "role" "img")
        , Region.description config.label
        , Element.htmlAttribute (Html.Attributes.attribute "title" config.label)
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
