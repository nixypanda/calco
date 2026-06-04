module Data.ItemRef exposing (ItemRef, decoder, fallbackName, key, unique)

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
    uniqueHelp [] items
        |> List.reverse


uniqueHelp : List ItemRef -> List { a | item : ItemRef } -> List ItemRef
uniqueHelp seen items =
    case items of
        [] ->
            seen

        current :: rest ->
            if List.any (\item -> key item == key current.item) seen then
                uniqueHelp seen rest

            else
                uniqueHelp (current.item :: seen) rest
