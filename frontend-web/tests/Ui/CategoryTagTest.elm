module Ui.CategoryTagTest exposing (tests)

import Element
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.CategoryTag as CategoryTag exposing (CategoryTag(..))
import Ui.Theme as Theme


tests : Test
tests =
    describe "Ui.CategoryTag"
        [ describe "rows"
            [ test "packs categories two per row and collapses the remainder into one tag" <|
                \_ ->
                    Expect.all
                        [ \_ -> CategoryTag.rows [] |> Expect.equal []
                        , \_ ->
                            CategoryTag.rows [ "a" ]
                                |> Expect.equal [ [ CategoryTag "a" ] ]
                        , \_ ->
                            CategoryTag.rows [ "a", "b" ]
                                |> Expect.equal [ [ CategoryTag "a", CategoryTag "b" ] ]
                        , \_ ->
                            CategoryTag.rows [ "a", "b", "c" ]
                                |> Expect.equal
                                    [ [ CategoryTag "a", CategoryTag "b" ]
                                    , [ CategoryTag "c" ]
                                    ]
                        , \_ ->
                            CategoryTag.rows [ "a", "b", "c", "d" ]
                                |> Expect.equal
                                    [ [ CategoryTag "a", CategoryTag "b" ]
                                    , [ CategoryTag "c", CategoryTag "d" ]
                                    ]
                        , \_ ->
                            CategoryTag.rows [ "a", "b", "c", "d", "e" ]
                                |> Expect.equal
                                    [ [ CategoryTag "a", CategoryTag "b" ]
                                    , [ CategoryTag "c", CategoryOverflowTag 2 ]
                                    ]
                        ]
                        ()
            ]
        , describe "view"
            [ test "renders the overflow tag" <|
                \_ ->
                    CategoryTag.view
                        Theme.light
                        Util.EN_US
                        (CategoryTag.rows [ "a", "b", "c", "d", "e" ])
                        |> Element.layout []
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "+2 more" ]
            ]
        ]
