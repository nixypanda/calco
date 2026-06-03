module Data.Quantity exposing (Quantity, decoder)

import Json.Decode as Decode exposing (Decoder)


type alias Quantity =
    { amount : String
    , unit : String
    }


decoder : Decoder Quantity
decoder =
    Decode.map2 Quantity
        (Decode.field "amount" Decode.string)
        (Decode.field "unit" Decode.string)
