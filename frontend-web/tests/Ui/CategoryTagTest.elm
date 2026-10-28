module Ui.CategoryTagTest exposing (tests)

{-| One property for the `Ui.CategoryTag.rows` layout decision, plus the one
allowed overflow render.

`rows` is a pure layout decision, so its whole contract is asserted as a single
`Expect.all`: at most two rows of at most two cells, input-order prefix, all
categories fit up to four, and one overflow cell counting `n - 3` only when
`n > 4`.

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
        [ fuzz categories "rows preserve order and hide only the overflow remainder" <|
            \input ->
                let
                    tagRows : List (List CategoryTag)
                    tagRows =
                        CategoryTag.rows input

                    names : List String
                    names =
                        categoryNames tagRows

                    counts : List Int
                    counts =
                        overflowCounts tagRows

                    inputLength : Int
                    inputLength =
                        List.length input
                in
                Expect.all
                    [ \_ -> List.length tagRows |> Expect.atMost 2
                    , \_ ->
                        tagRows
                            |> List.all (\cells -> List.length cells <= 2)
                            |> Expect.equal True
                    , \_ -> names |> Expect.equal (List.take (List.length names) input)
                    , \_ ->
                        if inputLength <= 4 then
                            Expect.all
                                [ \_ -> names |> Expect.equal input
                                , \_ -> counts |> Expect.equal []
                                , \_ -> cellCount tagRows |> Expect.equal inputLength
                                ]
                                ()

                        else
                            Expect.all
                                [ \_ -> names |> Expect.equal (List.take 3 input)
                                , \_ -> counts |> Expect.equal [ inputLength - 3 ]
                                , \_ -> cellCount tagRows |> Expect.equal 4
                                ]
                                ()
                    , \_ ->
                        List.length names
                            + List.sum counts
                            |> Expect.equal inputLength
                    ]
                    ()
        , {- Allowed render exception: the translated overflow label is only
             observable after `view` renders it, which is not expressible as a
             pure `rows` property; a full page story does not own this layout
             helper.
          -}
          test "the overflow tag shows the visible remainder and hides the rest" <|
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
