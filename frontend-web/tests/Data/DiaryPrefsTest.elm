module Data.DiaryPrefsTest exposing (tests)

import Data.DiaryPrefs as DiaryPrefs
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.DiaryPrefs"
        [ test "decodes enabled meal slots" <|
            \_ ->
                Decode.decodeString DiaryPrefs.decoder
                    "{\"enabled_meal_slots\":[\"breakfast\",\"late_night_snack\"]}"
                    |> Expect.equal
                        (Ok { enabledMealSlots = [ Breakfast, LateNightSnack ] })
        , test "rejects unknown catalogue values" <|
            \_ ->
                Decode.decodeString DiaryPrefs.decoder
                    "{\"enabled_meal_slots\":[\"midnight\"]}"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "encodes complete selection" <|
            \_ ->
                { enabledMealSlots = [ Lunch, LateNightSnack ] }
                    |> DiaryPrefs.encoder
                    |> Encode.encode 0
                    |> Expect.equal
                        "{\"enabled_meal_slots\":[\"lunch\",\"late_night_snack\"]}"
        ]
