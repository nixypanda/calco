module Lib.ListExtra exposing (removeAt, updateAt)


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
