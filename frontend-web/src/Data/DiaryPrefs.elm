module Data.DiaryPrefs exposing
    ( DiaryPrefs
    , decoder
    , encoder
    , isEnabled
    )

import Data.MealSlot as MealSlot exposing (MealSlot)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias DiaryPrefs =
    { enabledMealSlots : List MealSlot }


decoder : Decoder DiaryPrefs
decoder =
    Decode.map DiaryPrefs
        (Decode.field "enabled_meal_slots"
            (Decode.list
                (Decode.string
                    |> Decode.andThen
                        (\raw ->
                            case MealSlot.fromString raw of
                                Just slot ->
                                    Decode.succeed slot

                                Nothing ->
                                    Decode.fail ("Unknown meal slot: " ++ raw)
                        )
                )
            )
        )


encoder : DiaryPrefs -> Encode.Value
encoder prefs =
    Encode.object
        [ ( "enabled_meal_slots"
          , prefs.enabledMealSlots
                |> List.map (MealSlot.toString >> Encode.string)
                |> Encode.list identity
          )
        ]


isEnabled : MealSlot -> DiaryPrefs -> Bool
isEnabled slot prefs =
    List.member slot prefs.enabledMealSlots
