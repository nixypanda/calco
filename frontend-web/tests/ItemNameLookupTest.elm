module ItemNameLookupTest exposing (tests)

import Data.ItemNameLookup as ItemNameLookup
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.ItemNameLookup"
        [ test "next missing product id skips duplicates and loaded names" <|
            \_ ->
                ItemNameLookup.empty
                    |> ItemNameLookup.insertProduct "food-1" "Rice"
                    |> ItemNameLookup.nextMissingProductId Nothing
                        [ "food-1", "food-2", "food-2" ]
                    |> Expect.equal (Just "food-2")
        ]
