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
        ]
