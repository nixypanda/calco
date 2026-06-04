module TextTest exposing (tests)

import Expect
import Lib.Text as Text
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Lib.Text"
        [ test "blank strings become Nothing" <|
            \_ ->
                Text.blankToMaybe "   "
                    |> Expect.equal Nothing
        , test "non-blank strings are trimmed" <|
            \_ ->
                Text.blankToMaybe "  notes  "
                    |> Expect.equal (Just "notes")
        , test "trimOrDefault returns fallback for blanks" <|
            \_ ->
                Text.trimOrDefault "g" " "
                    |> Expect.equal "g"
        , test "commaSeparatedUniqueLower trims lowercases and deduplicates" <|
            \_ ->
                Text.commaSeparatedUniqueLower " Fruit, snack, fruit , SNACK "
                    |> Expect.equal [ "fruit", "snack" ]
        , test "splitQuotedWhitespace preserves spaces inside quotes" <|
            \_ ->
                Text.splitQuotedWhitespace "apple  category:\"food and"
                    |> Expect.equal [ "apple", " ", "", " ", "category:\"food and" ]
        , test "quoteIfWhitespace wraps values containing whitespace" <|
            \_ ->
                Text.quoteIfWhitespace "food and beverages"
                    |> Expect.equal "\"food and beverages\""
        ]
