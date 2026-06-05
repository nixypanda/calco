module Data.ItemRef exposing (ItemRef, decoder, encoder)

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias ItemRef =
    { itemType : String
    , id : String
    }


decoder : Decoder ItemRef
decoder =
    Decode.map2 ItemRef
        (Decode.field "type" Decode.string)
        (Decode.field "id" Decode.string)


encoder : ItemRef -> Encode.Value
encoder item =
    Encode.object
        [ ( "type", Encode.string item.itemType )
        , ( "id", Encode.string item.id )
        ]
