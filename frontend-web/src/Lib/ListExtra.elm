module Lib.ListExtra exposing (removeAt, uniqueBy, updateAt)


updateAt : Int -> (a -> a) -> List a -> List a
updateAt target change items =
    items
        |> List.indexedMap
            (\index item ->
                if index == target then
                    change item

                else
                    item
            )


removeAt : Int -> List a -> List a
removeAt target items =
    items
        |> List.indexedMap Tuple.pair
        |> List.filter (\( index, _ ) -> index /= target)
        |> List.map Tuple.second


uniqueBy : (a -> comparable) -> List a -> List a
uniqueBy toKey items =
    uniqueByHelp toKey [] items


uniqueByHelp : (a -> comparable) -> List comparable -> List a -> List a
uniqueByHelp toKey seen items =
    case items of
        [] ->
            []

        item :: rest ->
            let
                key : comparable
                key =
                    toKey item
            in
            if List.member key seen then
                uniqueByHelp toKey seen rest

            else
                item :: uniqueByHelp toKey (key :: seen) rest
