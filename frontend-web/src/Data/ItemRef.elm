module Data.ItemRef exposing
    ( ItemRef
    , ItemType(..)
    , decoder
    , encoder
    , itemTypeToString
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias ItemRef =
    { itemType : ItemType, id : String }


type ItemType
    = Product
    | Meal


itemTypeToString : ItemType -> String
itemTypeToString itemType =
    case itemType of
        Product ->
            "product"

        Meal ->
            "meal"


itemTypeDecoder : Decoder ItemType
itemTypeDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case raw of
                    "product" ->
                        Decode.succeed Product

                    "meal" ->
                        Decode.succeed Meal

                    _ ->
                        Decode.fail ("Unknown item type: " ++ raw)
            )


decoder : Decoder ItemRef
decoder =
    Decode.map2 ItemRef (Decode.field "type" itemTypeDecoder) (Decode.field "id" Decode.string)


encoder : ItemRef -> Encode.Value
encoder item =
    Encode.object
        [ ( "type", Encode.string (itemTypeToString item.itemType) )
        , ( "id", Encode.string item.id )
        ]
