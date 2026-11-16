module Ui.ButtonTest exposing (tests)

import Element
import Expect
import Html.Attributes as Attr
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Ui.Button as Button
import Ui.Icon as Icon
import Ui.Theme as Theme


tests : Test
tests =
    describe "Ui.Button.iconButton"
        [ test "a disabled icon button is static, not an unnamed tab target" <|
            \_ ->
                let
                    html : Query.Single ()
                    html =
                        Button.iconButton
                            { class = Element.Desktop, orientation = Element.Landscape }
                            Theme.light
                            { icon = Icon.ChevronRight
                            , title = ""
                            , onPress = Nothing
                            , tone = Button.Primary
                            }
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        html
                            |> Query.hasNot
                                [ Selector.attribute (Attr.attribute "role" "button") ]
                    , \_ ->
                        html
                            |> Query.hasNot
                                [ Selector.attribute (Attr.attribute "tabIndex" "0") ]
                    , \_ ->
                        html
                            |> Query.find [ Selector.tag "svg" ]
                            |> Query.has
                                [ Selector.attribute (Attr.attribute "aria-hidden" "true") ]
                    ]
                    ()
        , test "an active icon button keeps its accessible name and tab stop" <|
            \_ ->
                Button.iconButton
                    { class = Element.Desktop, orientation = Element.Landscape }
                    Theme.light
                    { icon = Icon.ChevronRight
                    , title = "Next Day"
                    , onPress = Just ()
                    , tone = Button.Primary
                    }
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.find
                        [ Selector.attribute (Attr.attribute "role" "button")
                        , Selector.attribute (Attr.attribute "aria-label" "Next Day")
                        ]
                    |> Query.has
                        [ Selector.attribute (Attr.attribute "title" "Next Day")
                        , Selector.attribute (Attr.attribute "tabIndex" "0")
                        ]
        ]
