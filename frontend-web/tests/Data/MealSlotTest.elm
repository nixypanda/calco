module Data.MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)


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
        , fuzz mealSlotFuzzer "formats and parses slots round trip" <|
            \slot ->
                slot
                    |> MealSlot.toString
                    |> MealSlot.fromString
                    |> Expect.equal (Just slot)
        , test "other matches missing or unknown backend slots" <|
            \_ ->
                [ MealSlot.matches Other Nothing
                , MealSlot.matches Other (Just "late")
                , MealSlot.matches Other (Just "lunch")
                ]
                    |> Expect.equal [ True, True, False ]
        ]


mealSlotFuzzer : Fuzzer MealSlot
mealSlotFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Breakfast
        , Fuzz.constant Lunch
        , Fuzz.constant Dinner
        , Fuzz.constant Snack
        , Fuzz.constant Other
        ]
