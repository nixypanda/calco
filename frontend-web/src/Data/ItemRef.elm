module Data.ItemRef exposing (ItemRef, decoder)

import Json.Decode as Decode exposing (Decoder)


type alias ItemRef =
    { itemType : String
    , id : String
    }


decoder : Decoder ItemRef
decoder =
    Decode.map2 ItemRef
        (Decode.field "type" Decode.string)
        (Decode.field "id" Decode.string)
