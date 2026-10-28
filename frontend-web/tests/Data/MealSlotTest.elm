module Data.MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.MealSlot"
        [ test "every slot roundtrips through its code" <|
            \_ ->
                MealSlot.all
                    |> List.all
                        (\slot -> MealSlot.fromString (MealSlot.toString slot) == Just slot)
                    |> Expect.equal True
        , fuzz Fuzz.string "fromString agrees with toString and rejects near misses" <|
            \raw ->
                Expect.all
                    [ \_ ->
                        MealSlot.fromString raw
                            |> Expect.equal
                                (MealSlot.all
                                    |> List.filter (\slot -> MealSlot.toString slot == raw)
                                    |> List.head
                                )
                    , \_ ->
                        [ ""
                        , "brunch"
                        , " breakfast"
                        , "breakfast "
                        , "BREAKFAST"
                        , "late_night_snack "
                        , "dinner\n"
                        ]
                            |> List.all (\nearMiss -> MealSlot.fromString nearMiss == Nothing)
                            |> Expect.equal True
                    ]
                    ()
        ]
