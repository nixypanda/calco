module Data.ItemRef exposing (ItemRef, decoder, encoder, fallbackName, key, unique)

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Lib.ListExtra as ListExtra


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


key : { a | itemType : String, id : String } -> String
key item =
    item.itemType ++ ":" ++ item.id


fallbackName : { a | itemType : String } -> String
fallbackName item =
    case item.itemType of
        "meal" ->
            "Unknown meal"

        _ ->
            "Unknown food"


unique : List { a | item : ItemRef } -> List ItemRef
unique items =
    items
        |> List.map .item
        |> ListExtra.uniqueBy key
