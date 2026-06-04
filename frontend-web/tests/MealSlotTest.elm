module MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.MealSlot"
        [ test "parses known slot" <|
            \_ ->
                MealSlot.fromString "lunch"
                    |> Expect.equal (Just Lunch)
        , test "rejects unknown slot" <|
            \_ ->
                MealSlot.fromString "midnight"
                    |> Expect.equal Nothing
        , test "formats slot for backend and route values" <|
            \_ ->
                MealSlot.toString Dinner
                    |> Expect.equal "dinner"
        , test "other matches missing or unknown backend slots" <|
            \_ ->
                [ MealSlot.matches Other Nothing
                , MealSlot.matches Other (Just "late")
                , MealSlot.matches Other (Just "lunch")
                ]
                    |> Expect.equal [ True, True, False ]
        ]
