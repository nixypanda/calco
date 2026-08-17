module Data.SearchTest exposing (tests)

import Data.Search as Search
import Expect
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
        [ test "completes include category operator" <|
            \_ ->
                Search.completions "c" []
                    |> Expect.equal [ Search.OperatorCompletion "category:" ]
        , test "completes exclude category operator" <|
            \_ ->
                Search.completions "-c" []
                    |> Expect.equal [ Search.OperatorCompletion "-category:" ]
        , test "returns no completions for empty or whitespace query" <|
            \_ ->
                ( Search.completions "" []
                , Search.completions "   " []
                )
                    |> Expect.equal ( [], [] )
        , test "applies completion to current token" <|
            \_ ->
                Search.applyCompletion (Search.OperatorCompletion "category:") "apple c"
                    |> Expect.equal "apple category:"
        , test "preserves repeated spaces before current token" <|
            \_ ->
                Search.applyCompletion (Search.OperatorCompletion "category:") "apple  c"
                    |> Expect.equal "apple  category:"
        , test "extracts category query value" <|
            \_ ->
                Search.categoryQuery "category:foo"
                    |> Expect.equal (Just "foo")
        , test "strips leading quote from partial category query value" <|
            \_ ->
                Search.categoryQuery "category:\"food and"
                    |> Expect.equal (Just "food and")
        , test "quotes category suggestions containing whitespace" <|
            \_ ->
                Search.completions
                    "category:foo"
                    [ { value = "food and beverages", count = 4 } ]
                    |> Expect.equal
                        [ Search.CategoryCompletion "category:\"food and beverages\"" 4 ]
        , test "quoted category tokens do not split on spaces" <|
            \_ ->
                Search.categoryQuery "apple category:\"food and"
                    |> Expect.equal (Just "food and")
        , test "empty starts with empty query and zero tokens" <|
            \_ ->
                Search.empty
                    |> Expect.equal
                        { query = ""
                        , searchToken = 0
                        , categoryToken = 0
                        , categorySuggestions = []
                        }
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
                        , searchToken = 1
                        , categoryToken = 1
                        , categoryReq = Nothing
                        }
        , test "onQueryChanged clears category suggestions when not a category value" <|
            \_ ->
                let
                    ( next, _ ) =
                        Search.onQueryChanged "apple"
                            { query = ""
                            , searchToken = 0
                            , categoryToken = 0
                            , categorySuggestions = [ { value = "fruit", count = 2 } ]
                            }
                in
                next.categorySuggestions
                    |> Expect.equal []
        , test "onQueryChanged keeps category suggestions while typing a category value" <|
            \_ ->
                let
                    ( next, _ ) =
                        Search.onQueryChanged "category:foo"
                            { query = ""
                            , searchToken = 0
                            , categoryToken = 0
                            , categorySuggestions = [ { value = "fruit", count = 2 } ]
                            }
                in
                next.categorySuggestions
                    |> Expect.equal [ { value = "fruit", count = 2 } ]
        , test "onQueryChanged yields a category request when typing a category value" <|
            \_ ->
                let
                    ( _, categoryReq ) =
                        Search.onQueryChanged "category:foo" Search.empty
                in
                categoryReq
                    |> Expect.equal (Just { token = 1, query = "foo" })
        , test "onQueryChangedDebounced produces a cmd for non-empty queries" <|
            \_ ->
                let
                    ( _, cmd ) =
                        Search.onQueryChangedDebounced "apple" Search.empty debounce
                in
                cmd
                    |> Expect.notEqual Cmd.none
        , test "onQueryChangedDebounced suppresses the cmd for empty queries" <|
            \_ ->
                let
                    ( _, cmd ) =
                        Search.onQueryChangedDebounced "   " Search.empty debounce
                in
                cmd
                    |> Expect.equal Cmd.none
        , test "onQueryChangedDebounced transitions state like onQueryChanged" <|
            \_ ->
                let
                    ( debounced, _ ) =
                        Search.onQueryChangedDebounced "category:foo" Search.empty debounce

                    ( immediate, _ ) =
                        Search.onQueryChanged "category:foo" Search.empty
                in
                debounced
                    |> Expect.equal immediate
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
                    |> Search.setCategorySuggestions 3
                        [ { value = "chocolate", count = 9 } ]
                    |> Search.setCategorySuggestions 1
                        [ { value = "stale", count = 1 } ]
                    |> .categorySuggestions
                )
                    |> Expect.equal ( 3, [ { value = "chocolate", count = 9 } ] )
        , test "setCategorySuggestions drops stale responses" <|
            \_ ->
                Search.setCategorySuggestions 1
                    [ { value = "fruit", count = 2 } ]
                    { query = ""
                    , searchToken = 0
                    , categoryToken = 2
                    , categorySuggestions = []
                    }
                    |> .categorySuggestions
                    |> Expect.equal []
        , test "setCategorySuggestions applies matching responses" <|
            \_ ->
                Search.setCategorySuggestions 2
                    [ { value = "fruit", count = 2 } ]
                    { query = ""
                    , searchToken = 0
                    , categoryToken = 2
                    , categorySuggestions = []
                    }
                    |> .categorySuggestions
                    |> Expect.equal [ { value = "fruit", count = 2 } ]
        , test "withQuery replaces only the query" <|
            \_ ->
                Search.withQuery "apple"
                    { query = ""
                    , searchToken = 4
                    , categoryToken = 5
                    , categorySuggestions = [ { value = "fruit", count = 1 } ]
                    }
                    |> Expect.equal
                        { query = "apple"
                        , searchToken = 4
                        , categoryToken = 5
                        , categorySuggestions = [ { value = "fruit", count = 1 } ]
                        }
        ]
