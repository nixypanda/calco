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
            [ test "no categories produce no rows" <|
                \_ ->
                    CategoryTag.rows []
                        |> Expect.equal []
            , test "one category occupies one row" <|
                \_ ->
                    CategoryTag.rows [ "a" ]
                        |> Expect.equal [ [ CategoryTag "a" ] ]
            , test "two categories fill one row" <|
                \_ ->
                    CategoryTag.rows [ "a", "b" ]
                        |> Expect.equal [ [ CategoryTag "a", CategoryTag "b" ] ]
            , test "three categories use a second row" <|
                \_ ->
                    CategoryTag.rows [ "a", "b", "c" ]
                        |> Expect.equal
                            [ [ CategoryTag "a", CategoryTag "b" ]
                            , [ CategoryTag "c" ]
                            ]
            , test "four categories fill two rows without overflow" <|
                \_ ->
                    CategoryTag.rows [ "a", "b", "c", "d" ]
                        |> Expect.equal
                            [ [ CategoryTag "a", CategoryTag "b" ]
                            , [ CategoryTag "c", CategoryTag "d" ]
                            ]
            , test "five categories collapse the remainder into one tag" <|
                \_ ->
                    CategoryTag.rows [ "a", "b", "c", "d", "e" ]
                        |> Expect.equal
                            [ [ CategoryTag "a", CategoryTag "b" ]
                            , [ CategoryTag "c", CategoryOverflowTag 2 ]
                            ]
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
