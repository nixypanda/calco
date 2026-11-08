module Ui.Workspace exposing (PaneRole(..), paneVisibility, view)

import Element exposing (Device, Element)
import Element.Keyed
import Html.Attributes as Attr
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens


{-| A pane's role is supplied by the route plan, not inferred from its position,
so a Phone layout with only the contextual detail pane visible still reports
`detail`.
-}
type PaneRole
    = MainPane
    | DetailPane


{-| Panes are keyed by role so the virtual DOM keeps each pane tied to its own
node across navigation instead of reusing whatever node sits at the same index.

Side by side, each pane is its own scroll container, so a pane that leaves the
visible window stays mounted and is hidden with `display: none` — that is what
keeps its scroll offset alive, while still taking it out of layout, tab order,
and the accessibility tree. With a single visible pane there is no per-pane
scroll container to preserve (the document scrolls), so the panes outside the
window are dropped rather than mounted invisibly. That single pane still gets
`height fill`, because panes that centre themselves vertically — the login and
setup forms — have nothing to centre in if this wrapper shrinks to their own
height.

-}
view : Device -> List ( String, PaneRole, Element msg ) -> Element msg
view device panes =
    let
        withVisibility : List ( ( String, PaneRole, Element msg ), Bool )
        withVisibility =
            paneVisibility device panes

        sideBySide : Bool
        sideBySide =
            List.length (List.filter Tuple.second withVisibility) > 1
    in
    if sideBySide then
        Element.Keyed.row
            [ Element.centerX
            , Element.alignTop
            , Element.width (Element.fill |> Element.maximum 1520)
            , Element.height Element.fill
            , Element.spacing DesignTokens.space16
            , Element.paddingEach
                { top = DesignTokens.space24
                , right = DesignTokens.space24
                , bottom = 0
                , left = DesignTokens.space24
                }
            , Element.clip
            , Element.htmlAttribute (Attr.class "ui-workspace")
            , Element.htmlAttribute (Attr.style "min-height" "0")
            , Element.htmlAttribute (Attr.style "height" "calc(100vh - 58px)")
            , Element.htmlAttribute (Attr.style "height" "calc(100dvh - 58px)")
            ]
            (List.map scrollingPane withVisibility)

    else
        case List.filter Tuple.second withVisibility of
            [ ( ( key, role, content ), _ ) ] ->
                Element.Keyed.el
                    ([ Element.centerX
                     , Element.width (Element.fill |> Element.maximum 960)
                     , Element.height Element.fill
                     , Element.padding
                        (if device.class == Element.Phone then
                            DesignTokens.space16

                         else
                            DesignTokens.space24
                        )
                     ]
                        ++ paneMarkerAttrs role
                    )
                    ( key, pageContent content )

            _ ->
                Element.none


paneVisibility : Device -> List key -> List ( key, Bool )
paneVisibility device keys =
    let
        hiddenCount : Int
        hiddenCount =
            List.length keys - paneLimit device
    in
    List.indexedMap (\index key -> ( key, index >= hiddenCount )) keys


scrollingPane : ( ( String, PaneRole, Element msg ), Bool ) -> ( String, Element msg )
scrollingPane ( ( key, role, content ), visible ) =
    ( key
    , Element.column
        (paneMarkerAttrs role
            ++ (if visible then
                    [ Element.width (Element.fillPortion 1)
                    , Element.height Element.fill
                    , Element.alignTop
                    , Element.scrollbarY
                    , Element.htmlAttribute (Attr.class "ui-workspace-pane")
                    , Element.htmlAttribute (Attr.style "min-height" "0")
                    , Element.htmlAttribute (Attr.style "overscroll-behavior-y" "contain")
                    ]

                else
                    [ hidden ]
               )
        )
        [ pageContent content ]
    )


{-| The page body keeps its own scroll/fill behaviour; this wrapper only carries
the harness hook, so it must mirror the pane's fill height.
-}
pageContent : Element msg -> Element msg
pageContent content =
    Element.el
        [ Element.width Element.fill
        , Element.height Element.fill
        , UiCommon.testId "page-content"
        ]
        content


paneMarkerAttrs : PaneRole -> List (Element.Attribute msg)
paneMarkerAttrs role =
    [ UiCommon.testId "workspace-pane"
    , UiCommon.dataAttribute "data-pane" (paneRoleName role)
    ]


paneRoleName : PaneRole -> String
paneRoleName role =
    case role of
        MainPane ->
            "main"

        DetailPane ->
            "detail"


hidden : Element.Attribute msg
hidden =
    Element.htmlAttribute (Attr.style "display" "none")


paneLimit : Device -> Int
paneLimit device =
    case device.class of
        Element.Phone ->
            1

        Element.Tablet ->
            1

        Element.Desktop ->
            2

        Element.BigDesktop ->
            2
