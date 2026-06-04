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
        ]
