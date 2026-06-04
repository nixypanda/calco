module Data.ItemRef exposing (ItemRef, decoder, fallbackName, key, unique)

import Json.Decode as Decode exposing (Decoder)
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


key : ItemRef -> String
key item =
    item.itemType ++ ":" ++ item.id


fallbackName : ItemRef -> String
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
