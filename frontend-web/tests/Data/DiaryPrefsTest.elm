module Data.DiaryPrefsTest exposing (tests)

import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Data.MealSlot as MealSlot
import Expect
import Json.Decode as Decode
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.DiaryPrefs"
        [ fuzz Support.mealSlotList
            "decoder after encoder returns the same slots in order, including duplicates"
          <|
            \slots ->
                let
                    prefs : DiaryPrefs
                    prefs =
                        { enabledMealSlots = slots }
                in
                Decode.decodeValue DiaryPrefs.decoder (DiaryPrefs.encoder prefs)
                    |> Expect.equal (Ok prefs)
        , test "encoder and decoder preserve duplicate slots in order" <|
            \_ ->
                let
                    prefs : DiaryPrefs
                    prefs =
                        { enabledMealSlots =
                            [ MealSlot.Breakfast
                            , MealSlot.Breakfast
                            , MealSlot.LateNightSnack
                            ]
                        }
                in
                Decode.decodeValue DiaryPrefs.decoder (DiaryPrefs.encoder prefs)
                    |> Expect.equal (Ok prefs)
        ]
