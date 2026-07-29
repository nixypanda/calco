module Ui.Workspace exposing (view)

import Element exposing (Device, Element)
import Html.Attributes as Attr
import Ui.DesignTokens as DesignTokens


view : Device -> List (Element msg) -> Element msg
view device panes =
    let
        visiblePanes : List (Element msg)
        visiblePanes =
            takeLast (paneLimit device) panes

        pane : Element msg -> Element msg
        pane content =
            Element.column
                [ Element.width (Element.fillPortion 1)
                , Element.height Element.fill
                , Element.alignTop
                , Element.scrollbarY
                , Element.htmlAttribute (Attr.class "ui-workspace-pane")
                , Element.htmlAttribute (Attr.style "min-height" "0")
                , Element.htmlAttribute
                    (Attr.style "overscroll-behavior-y" "contain")
                ]
                [ content ]
    in
    case visiblePanes of
        [ only ] ->
            Element.el
                [ Element.centerX
                , Element.width (Element.fill |> Element.maximum 960)
                , Element.padding
                    (if device.class == Element.Phone then
                        DesignTokens.space16

                     else
                        DesignTokens.space24
                    )
                ]
                only

        _ ->
            Element.row
                [ Element.centerX
                , Element.alignTop
                , Element.width (Element.fill |> Element.maximum 1520)
                , Element.height Element.fill
                , Element.spacing DesignTokens.space16
                , Element.padding DesignTokens.space24
                , Element.clip
                , Element.htmlAttribute (Attr.class "ui-workspace")
                , Element.htmlAttribute (Attr.style "min-height" "0")
                , Element.htmlAttribute
                    (Attr.style "height" "calc(100vh - 58px)")
                , Element.htmlAttribute
                    (Attr.style "height" "calc(100dvh - 58px)")
                ]
                (List.map pane visiblePanes)


paneLimit : Device -> Int
paneLimit device =
    case device.class of
        Element.Phone ->
            1

        Element.Tablet ->
            2

        Element.Desktop ->
            2

        Element.BigDesktop ->
            2


takeLast : Int -> List a -> List a
takeLast count items =
    items
        |> List.reverse
        |> List.take count
        |> List.reverse
