module Data.DiaryPreferencesTest exposing (tests)

import Data.DiaryPreferences as DiaryPreferences
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.DiaryPreferences"
        [ test "decodes enabled meal slots" <|
            \_ ->
                Decode.decodeString DiaryPreferences.decoder
                    "{\"enabled_meal_slots\":[\"breakfast\",\"late_night_snack\"]}"
                    |> Expect.equal
                        (Ok { enabledMealSlots = [ Breakfast, LateNightSnack ] })
        , test "rejects unknown catalogue values" <|
            \_ ->
                Decode.decodeString DiaryPreferences.decoder
                    "{\"enabled_meal_slots\":[\"midnight\"]}"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "encodes complete selection" <|
            \_ ->
                { enabledMealSlots = [ Lunch, LateNightSnack ] }
                    |> DiaryPreferences.encoder
                    |> Encode.encode 0
                    |> Expect.equal
                        "{\"enabled_meal_slots\":[\"lunch\",\"late_night_snack\"]}"
        ]
