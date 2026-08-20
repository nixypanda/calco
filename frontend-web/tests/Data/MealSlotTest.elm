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
        , test "supports late-night snack" <|
            \_ ->
                ( MealSlot.fromString "late_night_snack"
                , MealSlot.toString LateNightSnack
                , MealSlot.label LateNightSnack
                )
                    |> Expect.equal
                        ( Just LateNightSnack
                        , "late_night_snack"
                        , "Late-night Snack"
                        )
        , test "catalogue has canonical fixed order" <|
            \_ ->
                MealSlot.all
                    |> Expect.equal
                        [ Breakfast, Lunch, Dinner, Snack, LateNightSnack ]
        , fuzz mealSlotFuzzer "formats and parses slots round trip" <|
            \slot ->
                slot
                    |> MealSlot.toString
                    |> MealSlot.fromString
                    |> Expect.equal (Just slot)
        , test "every slot formats to a value the backend accepts" <|
            \_ ->
                List.map MealSlot.toString MealSlot.all
                    |> Expect.equal
                        [ "breakfast"
                        , "lunch"
                        , "dinner"
                        , "snack"
                        , "late_night_snack"
                        ]
        , test "rejects the unslotted bucket's label as a slot" <|
            \_ ->
                MealSlot.fromString "other"
                    |> Expect.equal Nothing
        ]


mealSlotFuzzer : Fuzzer MealSlot
mealSlotFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Breakfast
        , Fuzz.constant Lunch
        , Fuzz.constant Dinner
        , Fuzz.constant Snack
        , Fuzz.constant LateNightSnack
        ]
