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
            , test "many categories count every hidden label" <|
                \_ ->
                    CategoryTag.rows
                        (List.map (\n -> "c" ++ String.fromInt n) (List.range 1 10))
                        |> Expect.equal
                            [ [ CategoryTag "c1", CategoryTag "c2" ]
                            , [ CategoryTag "c3", CategoryOverflowTag 7 ]
                            ]
            , test "a long list never exceeds two rows of two tags" <|
                \_ ->
                    CategoryTag.rows (List.repeat 50 "x")
                        |> (\tagRows -> ( List.length tagRows, List.map List.length tagRows ))
                        |> Expect.equal ( 2, [ 2, 2 ] )
            ]
        , describe "view"
            [ test "renders one chip per visible tag" <|
                \_ ->
                    CategoryTag.view Theme.light Util.EN_US (CategoryTag.rows [ "a", "b", "c" ])
                        |> Element.layout []
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.class "ui-chip" ]
                        |> Query.count (Expect.equal 3)
            , test "renders the overflow tag" <|
                \_ ->
                    CategoryTag.view
                        Theme.light
                        Util.EN_US
                        (CategoryTag.rows [ "a", "b", "c", "d", "e" ])
                        |> Element.layout []
                        |> Query.fromHtml
                        |> Query.has [ Selector.text "+2 more" ]
            , test "caps a long list at four chips" <|
                \_ ->
                    CategoryTag.view Theme.light Util.EN_US (CategoryTag.rows (List.repeat 20 "x"))
                        |> Element.layout []
                        |> Query.fromHtml
                        |> Query.findAll [ Selector.class "ui-chip" ]
                        |> Query.count (Expect.equal 4)
            ]
        ]
