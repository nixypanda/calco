module Data.FoodLogTest exposing (tests)

import Data.FoodLog as FoodLog
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.FoodLog"
        [ {- Intentional decoder leniency (plan section 6.5): an unknown meal
             slot decodes as `Nothing` instead of rejecting the whole log. This
             cannot be expressed as a roundtrip because the wire value has no
             domain representation.
          -}
          test "an unknown meal slot decodes as Nothing" <|
            \_ ->
                Decode.decodeValue FoodLog.decoder unknownSlotLog
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok Nothing)
        ]


unknownSlotLog : Encode.Value
unknownSlotLog =
    Encode.object
        [ ( "id", Encode.string "log-1" )
        , ( "log_date", Encode.string "2024-01-01" )
        , ( "device_timezone", Encode.null )
        , ( "meal_slot", Encode.string "brunch" )
        , ( "item"
          , Encode.object
                [ ( "type", Encode.string "ad_hoc" )
                , ( "name", Encode.string "Toast" )
                ]
          )
        , ( "quantity"
          , Encode.object
                [ ( "amount", Encode.string "1" )
                , ( "unit", Encode.string "g" )
                ]
          )
        , ( "nutrients", Encode.list Encode.string [] )
        , ( "notes", Encode.null )
        ]
