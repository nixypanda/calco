module Data.MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot exposing (MealSlot)
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.MealSlot"
        [ test "every slot roundtrips through its code" <|
            \_ ->
                MealSlot.all
                    |> List.map
                        (\slot ->
                            MealSlot.fromString (MealSlot.toString slot)
                                |> Expect.equal (Just slot)
                        )
                    |> expectAll
        , test "toString is injective over all slots" <|
            \_ ->
                allPairs
                    |> List.all distinctCodes
                    |> Expect.equal True
        , fuzz Fuzz.string "fromString s is the first slot whose code equals s" <|
            \raw ->
                MealSlot.fromString raw
                    |> Expect.equal
                        (MealSlot.all
                            |> List.filter (\slot -> MealSlot.toString slot == raw)
                            |> List.head
                        )
        , test "fromString rejects near-miss codes" <|
            \_ ->
                [ ""
                , "brunch"
                , " breakfast"
                , "breakfast "
                , "BREAKFAST"
                , "late_night_snack "
                , "dinner\n"
                ]
                    |> List.map (MealSlot.fromString >> Expect.equal Nothing)
                    |> expectAll
        ]


allPairs : List ( MealSlot, MealSlot )
allPairs =
    List.concatMap
        (\left -> List.map (\right -> ( left, right )) MealSlot.all)
        MealSlot.all


distinctCodes : ( MealSlot, MealSlot ) -> Bool
distinctCodes ( left, right ) =
    left == right || MealSlot.toString left /= MealSlot.toString right


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()
