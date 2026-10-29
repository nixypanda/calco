module Data.MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.MealSlot"
        [ test "every slot roundtrips through its code" <|
            \_ ->
                MealSlot.all
                    |> List.all
                        (\slot -> MealSlot.fromString (MealSlot.toString slot) == Just slot)
                    |> Expect.equal True
        , test "fromString rejects near misses" <|
            \_ ->
                Expect.all
                    [ \_ ->
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
