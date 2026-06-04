module ItemNameLookupTest exposing (tests)

import Data.ItemNameLookup as ItemNameLookup
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.ItemNameLookup"
        [ test "result insertion stores successful names" <|
            \_ ->
                ItemNameLookup.empty
                    |> ItemNameLookup.insertResult mealRef (Ok "Lunch")
                    |> ItemNameLookup.nameFor "Loading..." mealRef
                    |> Expect.equal "Lunch"
        , test "result insertion stores fallback names on failure" <|
            \_ ->
                ItemNameLookup.empty
                    |> ItemNameLookup.insertResult mealRef (Err ())
                    |> ItemNameLookup.nameFor "Loading..." mealRef
                    |> Expect.equal "Unknown meal"
        , test "next missing product id skips duplicates and loaded names" <|
            \_ ->
                ItemNameLookup.empty
                    |> ItemNameLookup.insertProduct "food-1" "Rice"
                    |> ItemNameLookup.nextMissingProductId Nothing
                        [ "food-1", "food-2", "food-2" ]
                    |> Expect.equal (Just "food-2")
        ]


mealRef : { itemType : String, id : String }
mealRef =
    { itemType = "meal", id = "meal-1" }
