module Ui.CategoryTagTest exposing (tests)

{-| Laws for `Ui.CategoryTag.rows`, plus the one allowed overflow render.

`rows` is a pure layout decision. The render below asserts only user-visible
overflow text; CSS and DOM structure are deliberately not asserted.

-}

import Element
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.CategoryTag as CategoryTag exposing (CategoryTag(..))
import Ui.Theme as Theme


tests : Test
tests =
    describe "Ui.CategoryTag"
        [ describe "rows"
            [ fuzz categories "at most two rows" <|
                \input ->
                    CategoryTag.rows input
                        |> List.length
                        |> Expect.atMost 2
            , fuzz categories "at most two cells per row" <|
                \input ->
                    CategoryTag.rows input
                        |> List.map List.length
                        |> List.all (\size -> size <= 2)
                        |> Expect.equal True
            , fuzz categories "categories appear in input order as a prefix" <|
                \input ->
                    let
                        names : List String
                        names =
                            CategoryTag.rows input |> categoryNames
                    in
                    names
                        |> Expect.equal (List.take (List.length names) input)
            , fuzz (Fuzz.listOfLengthBetween 0 4 Fuzz.string) "up to four categories all fit" <|
                \input ->
                    let
                        tagRows : List (List CategoryTag)
                        tagRows =
                            CategoryTag.rows input
                    in
                    Expect.all
                        [ \_ -> categoryNames tagRows |> Expect.equal input
                        , \_ -> overflowCounts tagRows |> Expect.equal []
                        , \_ -> cellCount tagRows |> Expect.equal (List.length input)
                        ]
                        ()
            , fuzz overFourCategories "more than four categories keep three and hide the rest" <|
                \input ->
                    let
                        tagRows : List (List CategoryTag)
                        tagRows =
                            CategoryTag.rows input
                    in
                    Expect.all
                        [ \_ -> categoryNames tagRows |> Expect.equal (List.take 3 input)
                        , \_ ->
                            overflowCounts tagRows
                                |> Expect.equal [ List.length input - 3 ]
                        , \_ -> cellCount tagRows |> Expect.equal 4
                        ]
                        ()
            , fuzz categories "represented categories plus overflow count equal input length" <|
                \input ->
                    let
                        tagRows : List (List CategoryTag)
                        tagRows =
                            CategoryTag.rows input
                    in
                    List.length (categoryNames tagRows)
                        + List.sum (overflowCounts tagRows)
                        |> Expect.equal (List.length input)
            , fuzz categories "rows is empty only for empty input" <|
                \input ->
                    CategoryTag.rows input
                        |> List.isEmpty
                        |> Expect.equal (List.isEmpty input)
            ]
        , test "the overflow tag shows the visible remainder and hides the rest" <|
            \_ ->
                CategoryTag.view Theme.light
                    Util.EN_US
                    (CategoryTag.rows [ "a", "b", "c", "d", "e" ])
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Expect.all
                        [ Query.has [ Selector.text "+2 more" ]
                        , Query.hasNot [ Selector.exactText "d" ]
                        , Query.hasNot [ Selector.exactText "e" ]
                        ]
        ]


categories : Fuzzer (List String)
categories =
    Fuzz.list Fuzz.string


overFourCategories : Fuzzer (List String)
overFourCategories =
    Fuzz.listOfLengthBetween 5 25 Fuzz.string


categoryNames : List (List CategoryTag) -> List String
categoryNames tagRows =
    List.concatMap (List.filterMap nameOf) tagRows


nameOf : CategoryTag -> Maybe String
nameOf tag =
    case tag of
        CategoryTag name ->
            Just name

        CategoryOverflowTag _ ->
            Nothing


overflowCounts : List (List CategoryTag) -> List Int
overflowCounts tagRows =
    List.concatMap (List.filterMap overflowOf) tagRows


overflowOf : CategoryTag -> Maybe Int
overflowOf tag =
    case tag of
        CategoryTag _ ->
            Nothing

        CategoryOverflowTag count ->
            Just count


cellCount : List (List CategoryTag) -> Int
cellCount tagRows =
    List.sum (List.map List.length tagRows)
