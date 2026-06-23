module Lib.ListExtra exposing (combineErrors, groupsOf, removeAt, uniqueBy, updateAt)


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


{-| Group elements into pairs. Trailing singletons are dropped. Used for
2×2 grid layouts.
-}
groupsOf : Int -> List a -> List ( a, a )
groupsOf n list =
    let
        step : Int -> List a -> List ( a, a ) -> List ( a, a )
        step _ remaining acc =
            case remaining of
                x :: y :: rest ->
                    step n rest (( x, y ) :: acc)

                _ ->
                    List.reverse acc
    in
    step n list []


{-| Combine a list of Results into a Result containing a list.
If any Result is an Err, the first Err is returned.
-}
combineErrors : List (Result e a) -> Result e (List a)
combineErrors results =
    case results of
        [] ->
            Ok []

        x :: xs ->
            case x of
                Err e ->
                    Err e

                Ok v ->
                    combineErrors xs |> Result.map (\rest -> v :: rest)
