module Data.ItemNameLookup exposing
    ( Names
    , empty
    , insert
    , insertProduct
    , insertResult
    , nameFor
    , nextMissingProductId
    , productRef
    , uniqueProductIds
    )

import Data.ItemRef as ItemRef exposing (ItemRef)
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


insert : ItemRef -> String -> Names -> Names
insert item name names =
    Dict.insert (ItemRef.key item) name names


insertProduct : String -> String -> Names -> Names
insertProduct id name names =
    insert (productRef id) name names


insertResult : ItemRef -> Result error String -> Names -> Names
insertResult item result names =
    insert item
        (case result of
            Ok name ->
                name

            Err _ ->
                ItemRef.fallbackName item
        )
        names


nameFor : String -> ItemRef -> Names -> String
nameFor fallback item names =
    Dict.get (ItemRef.key item) names
        |> Maybe.withDefault fallback


isLoaded : ItemRef -> Names -> Bool
isLoaded item names =
    Dict.member (ItemRef.key item) names


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
