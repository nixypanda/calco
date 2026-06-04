module Data.Quantity exposing (Quantity, decoder, encoder)

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias Quantity =
    { amount : String
    , unit : String
    }


decoder : Decoder Quantity
decoder =
    Decode.map2 Quantity
        (Decode.field "amount" Decode.string)
        (Decode.field "unit" Decode.string)


encoder : Quantity -> Encode.Value
encoder quantity =
    Encode.object
        [ ( "amount", Encode.string quantity.amount )
        , ( "unit", Encode.string quantity.unit )
        ]
