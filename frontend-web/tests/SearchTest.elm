module SearchTest exposing (tests)

import Data.Search as Search
import Expect
import Test exposing (Test, describe, test)


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
                    ( next, cmd, categoryReq ) =
                        Search.onQueryChanged "apple" Search.empty Nothing
                in
                { query = next.query
                , searchToken = next.searchToken
                , categoryToken = next.categoryToken
                , hasCmd = cmd /= Cmd.none
                , categoryReq = categoryReq
                }
                    |> Expect.equal
                        { query = "apple"
                        , searchToken = 1
                        , categoryToken = 1
                        , hasCmd = False
                        , categoryReq = Nothing
                        }
        , test "onQueryChanged clears category suggestions when not a category value" <|
            \_ ->
                let
                    ( next, _, _ ) =
                        Search.onQueryChanged "apple"
                            { query = ""
                            , searchToken = 0
                            , categoryToken = 0
                            , categorySuggestions = [ { value = "fruit", count = 2 } ]
                            }
                            Nothing
                in
                next.categorySuggestions
                    |> Expect.equal []
        , test "onQueryChanged keeps category suggestions while typing a category value" <|
            \_ ->
                let
                    ( next, _, _ ) =
                        Search.onQueryChanged "category:foo"
                            { query = ""
                            , searchToken = 0
                            , categoryToken = 0
                            , categorySuggestions = [ { value = "fruit", count = 2 } ]
                            }
                            Nothing
                in
                next.categorySuggestions
                    |> Expect.equal [ { value = "fruit", count = 2 } ]
        , test "onQueryChanged yields a category request when typing a category value" <|
            \_ ->
                let
                    ( _, _, categoryReq ) =
                        Search.onQueryChanged "category:foo" Search.empty Nothing
                in
                categoryReq
                    |> Expect.equal (Just { token = 1, query = "foo" })
        , test "onQueryChanged produces a debounce cmd for non-empty queries when configured" <|
            \_ ->
                let
                    ( _, cmd, _ ) =
                        Search.onQueryChanged "apple"
                            Search.empty
                            (Just { delayMs = 0, onFire = \_ _ -> () })
                in
                cmd
                    |> Expect.notEqual Cmd.none
        , test "onQueryChanged suppresses debounce for empty queries" <|
            \_ ->
                let
                    ( _, cmd, _ ) =
                        Search.onQueryChanged "   "
                            Search.empty
                            (Just { delayMs = 0, onFire = \_ _ -> () })
                in
                cmd
                    |> Expect.equal Cmd.none
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
