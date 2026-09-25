module Data.MealSlotTest exposing (tests)

import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Expect
import Test exposing (Test, describe, test)
import Translations.Util as Util


tests : Test
tests =
    describe "Data.MealSlot"
        [ test "parses known slots and rejects unknown ones" <|
            \_ ->
                Expect.all
                    [ \_ -> MealSlot.fromString "lunch" |> Expect.equal (Just Lunch)
                    , \_ -> MealSlot.fromString "midnight" |> Expect.equal Nothing
                    ]
                    ()
        , test "supports late-night snack" <|
            \_ ->
                ( MealSlot.fromString "late_night_snack"
                , MealSlot.toString LateNightSnack
                , MealSlot.label Util.EN_US LateNightSnack
                )
                    |> Expect.equal
                        ( Just LateNightSnack
                        , "late_night_snack"
                        , "Late-night Snack"
                        )
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
        ]
