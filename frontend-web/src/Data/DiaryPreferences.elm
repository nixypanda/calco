module Data.DiaryPreferences exposing
    ( DiaryPreferences
    , decoder
    , encoder
    , isEnabled
    )

import Data.MealSlot as MealSlot exposing (MealSlot)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias DiaryPreferences =
    { enabledMealSlots : List MealSlot }


decoder : Decoder DiaryPreferences
decoder =
    Decode.map DiaryPreferences
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


encoder : DiaryPreferences -> Encode.Value
encoder preferences =
    Encode.object
        [ ( "enabled_meal_slots"
          , preferences.enabledMealSlots
                |> List.map (MealSlot.toString >> Encode.string)
                |> Encode.list identity
          )
        ]


isEnabled : MealSlot -> DiaryPreferences -> Bool
isEnabled slot preferences =
    List.member slot preferences.enabledMealSlots
