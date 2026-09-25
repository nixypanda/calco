module Data.SearchTest exposing (tests)

import Data.Search as Search
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Test exposing (Test, describe, test)


debounce : Search.Debounce ()
debounce =
    { delayMs = 0
    , onSearchElapsed = \_ _ -> ()
    , onCategoryElapsed = \_ _ -> ()
    }


tests : Test
tests =
    describe "Data.Search"
        [ test "completes include and exclude category operators" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Search.completions "c" []
                            |> Expect.equal [ Search.OperatorCompletion "category:" ]
                    , \_ ->
                        Search.completions "-c" []
                            |> Expect.equal [ Search.OperatorCompletion "-category:" ]
                    ]
                    ()
        , test "returns no completions for empty or whitespace query" <|
            \_ ->
                ( Search.completions "" []
                , Search.completions "   " []
                )
                    |> Expect.equal ( [], [] )
        , test "preserves repeated spaces before current token" <|
            \_ ->
                Search.applyCompletion (Search.OperatorCompletion "category:") "apple  c"
                    |> Expect.equal "apple  category:"
        , test "extracts category query values including quoted tokens" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Search.categoryQuery "category:foo"
                            |> Expect.equal (Just "foo")
                    , \_ ->
                        Search.categoryQuery "category:\"food and"
                            |> Expect.equal (Just "food and")
                    , \_ ->
                        Search.categoryQuery "apple category:\"food and"
                            |> Expect.equal (Just "food and")
                    ]
                    ()
        , test "quotes category suggestions containing whitespace" <|
            \_ ->
                Search.completions
                    "category:foo"
                    [ { value = "food and beverages", count = 4 } ]
                    |> Expect.equal
                        [ Search.CategoryCompletion "category:\"food and beverages\"" 4 ]
        , test "onQueryChanged trims and bumps tokens for non-empty queries" <|
            \_ ->
                let
                    ( next, categoryReq ) =
                        Search.onQueryChanged "apple" Search.empty
                in
                { query = next.query
                , searchToken = next.searchToken
                , categoryToken = next.categoryToken
                , categoryReq = categoryReq
                }
                    |> Expect.equal
                        { query = "apple"
                        , searchToken = ticket 1
                        , categoryToken = ticket 1
                        , categoryReq = Nothing
                        }
        , test "onQueryChanged manages category suggestions for plain and category values" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Search.onQueryChanged "apple"
                            (withSuggestions [ { value = "fruit", count = 2 } ])
                            |> Tuple.first
                            |> .categorySuggestions
                            |> Expect.equal []
                    , \_ ->
                        Search.onQueryChanged "category:foo"
                            (withSuggestions [ { value = "fruit", count = 2 } ])
                            |> Tuple.first
                            |> .categorySuggestions
                            |> Expect.equal [ { value = "fruit", count = 2 } ]
                    ]
                    ()
        , test "onQueryChanged yields a category request when typing a category value" <|
            \_ ->
                let
                    ( _, categoryReq ) =
                        Search.onQueryChanged "category:foo" Search.empty
                in
                categoryReq
                    |> Expect.equal (Just { token = ticket 1, query = "foo" })
        , test "onQueryChangedDebounced produces a cmd only for non-empty queries" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Search.onQueryChangedDebounced "apple" Search.empty debounce
                            |> Tuple.second
                            |> Expect.notEqual Cmd.none
                    , \_ ->
                        Search.onQueryChangedDebounced "   " Search.empty debounce
                            |> Tuple.second
                            |> Expect.equal Cmd.none
                    ]
                    ()
        , test "a burst of query changes leaves only the settled category token live" <|
            \_ ->
                let
                    settled : Search.QueryState
                    settled =
                        List.foldl
                            (\query state ->
                                let
                                    ( next, _ ) =
                                        Search.onQueryChangedDebounced query state debounce
                                in
                                next
                            )
                            Search.empty
                            [ "category:c", "category:ch", "category:cho" ]
                in
                ( settled.categoryToken
                , settled
                    |> Search.setCategorySuggestions (ticket 3)
                        [ { value = "chocolate", count = 9 } ]
                    |> Search.setCategorySuggestions (ticket 1)
                        [ { value = "stale", count = 1 } ]
                    |> .categorySuggestions
                )
                    |> Expect.equal ( ticket 3, [ { value = "chocolate", count = 9 } ] )
        , test "setCategorySuggestions drops stale and applies matching responses" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Search.setCategorySuggestions (ticket 1)
                            [ { value = "fruit", count = 2 } ]
                            (withToken (ticket 2))
                            |> .categorySuggestions
                            |> Expect.equal []
                    , \_ ->
                        Search.setCategorySuggestions (ticket 2)
                            [ { value = "fruit", count = 2 } ]
                            (withToken (ticket 2))
                            |> .categorySuggestions
                            |> Expect.equal [ { value = "fruit", count = 2 } ]
                    ]
                    ()
        ]


withSuggestions : List { value : String, count : Int } -> Search.QueryState
withSuggestions suggestions =
    { query = ""
    , searchToken = Ticket.initial
    , categoryToken = Ticket.initial
    , categorySuggestions = suggestions
    }


withToken : Ticket -> Search.QueryState
withToken categoryToken =
    { query = ""
    , searchToken = Ticket.initial
    , categoryToken = categoryToken
    , categorySuggestions = []
    }


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
