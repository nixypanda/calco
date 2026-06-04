module CategoryTest exposing (tests)

import Data.Category as Category
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.Category"
        [ test "splits trims lowercases and deduplicates categories" <|
            \_ ->
                Category.parseInput " Fruit, snack, fruit , SNACK "
                    |> Expect.equal [ "fruit", "snack" ]
        , test "ignores empty categories" <|
            \_ ->
                Category.parseInput "fruit, , , dairy"
                    |> Expect.equal [ "fruit", "dairy" ]
        , test "formats category input" <|
            \_ ->
                Category.formatInput [ "fruit", "snack" ]
                    |> Expect.equal "fruit, snack"
        ]
