module Data.DiaryPrefsTest exposing (tests)

import Data.DiaryPrefs as DiaryPrefs exposing (DiaryPrefs)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Data.DiaryPrefs"
        [ fuzz prefsSlotsFuzzer
            "decoder after encoder preserves order and duplicates"
          <|
            \slots ->
                let
                    prefs : DiaryPrefs
                    prefs =
                        { enabledMealSlots = slots }
                in
                Decode.decodeValue DiaryPrefs.decoder (DiaryPrefs.encoder prefs)
                    |> Expect.equal (Ok prefs)
        ]


prefsSlotsFuzzer : Fuzzer (List MealSlot)
prefsSlotsFuzzer =
    Fuzz.frequency
        [ ( 4, Support.mealSlotList )
        , ( 1
          , Fuzz.oneOfValues
                [ [ MealSlot.Breakfast, MealSlot.Breakfast, MealSlot.LateNightSnack ]
                , [ MealSlot.Lunch, MealSlot.Dinner, MealSlot.Lunch ]
                ]
          )
        ]
