module Lib.TextTest exposing (tests)

import Expect
import Lib.Text as Text
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Lib.Text"
        [ test "blankToMaybe trims non-blank strings and drops blanks" <|
            \_ ->
                Expect.all
                    [ \_ -> Text.blankToMaybe "   " |> Expect.equal Nothing
                    , \_ ->
                        Text.blankToMaybe "  notes  "
                            |> Expect.equal (Just "notes")
                    ]
                    ()
        , test "trimOrDefault returns fallback for blanks" <|
            \_ ->
                Text.trimOrDefault "g" " "
                    |> Expect.equal "g"
        , test "requireTrimmed rejects blank values with provided problem" <|
            \_ ->
                Text.requireTrimmed "required" "   "
                    |> Expect.equal (Err "required")
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
