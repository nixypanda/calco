module Data.ItemNameLookup exposing
    ( Names
    , empty
    , insertProduct
    , nameFor
    , nextMissingProductId
    , productRef
    , uniqueProductIds
    )

import Data.ItemRef exposing (ItemRef)
import Dict exposing (Dict)
import Lib.ListExtra as ListExtra


type alias Names =
    Dict String String


empty : Names
empty =
    Dict.empty


productRef : String -> ItemRef
productRef id =
    { itemType = "product", id = id }


key : { a | itemType : String, id : String } -> String
key item =
    item.itemType ++ ":" ++ item.id


insert : { a | itemType : String, id : String } -> String -> Names -> Names
insert item name names =
    Dict.insert (key item) name names


insertProduct : String -> String -> Names -> Names
insertProduct id name names =
    insert (productRef id) name names


nameFor : String -> { a | itemType : String, id : String } -> Names -> String
nameFor fallback item names =
    Dict.get (key item) names
        |> Maybe.withDefault fallback


isLoaded : ItemRef -> Names -> Bool
isLoaded item names =
    Dict.member (key item) names


uniqueProductIds : List String -> List String
uniqueProductIds ids =
    ListExtra.uniqueBy identity ids


nextMissingProductId : Maybe String -> List String -> Names -> Maybe String
nextMissingProductId completedId ids names =
    ids
        |> uniqueProductIds
        |> List.filter
            (\id ->
                Just id
                    /= completedId
                    && not (isLoaded (productRef id) names)
            )
        |> List.head
