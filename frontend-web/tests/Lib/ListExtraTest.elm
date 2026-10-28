module Lib.ListExtraTest exposing (tests)

import Expect
import Fuzz exposing (Fuzzer)
import Lib.ListExtra as ListExtra
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Lib.ListExtra"
        [ fuzz indexedList "updateAt never changes list length" <|
            \( index, items ) ->
                ListExtra.updateAt index change items
                    |> List.length
                    |> Expect.equal (List.length items)
        , fuzz outOfRangeIndexedList "updateAt leaves out-of-range indices unchanged" <|
            \( index, items ) ->
                ListExtra.updateAt index change items
                    |> Expect.equal items
        , fuzz inRangeIndexedList "updateAt changes only the target element" <|
            \( index, items ) ->
                let
                    updated : List Int
                    updated =
                        ListExtra.updateAt index change items

                    targetBefore : Maybe Int
                    targetBefore =
                        valueAt index items
                in
                Expect.all
                    [ \_ -> List.length updated |> Expect.equal (List.length items)
                    , \_ -> List.take index updated |> Expect.equal (List.take index items)
                    , \_ ->
                        List.drop (index + 1) updated
                            |> Expect.equal (List.drop (index + 1) items)
                    , \_ ->
                        valueAt index updated
                            |> Expect.equal (Maybe.map change targetBefore)
                    ]
                    ()
        , fuzz outOfRangeIndexedList "removeAt leaves out-of-range indices unchanged" <|
            \( index, items ) ->
                ListExtra.removeAt index items
                    |> Expect.equal items
        , fuzz inRangeIndexedList "removeAt removes only the target and preserves order" <|
            \( index, items ) ->
                let
                    removed : List Int
                    removed =
                        ListExtra.removeAt index items
                in
                Expect.all
                    [ \_ -> List.length removed |> Expect.equal (List.length items - 1)
                    , \_ -> List.take index removed |> Expect.equal (List.take index items)
                    , \_ ->
                        List.drop index removed
                            |> Expect.equal (List.drop (index + 1) items)
                    ]
                    ()
        , fuzz uniqueKeyedList "uniqueBy returns an idempotent key-distinct subsequence" <|
            \items ->
                let
                    unique : List ( Int, Int )
                    unique =
                        ListExtra.uniqueBy Tuple.first items

                    keys : List Int
                    keys =
                        List.map Tuple.first unique
                in
                Expect.all
                    [ \_ -> isSubsequenceOf unique items |> Expect.equal True
                    , \_ -> hasNoDuplicates keys |> Expect.equal True
                    , \_ ->
                        ListExtra.uniqueBy Tuple.first unique
                            |> Expect.equal unique
                    ]
                    ()
        , fuzz uniqueKeyedList
            "uniqueBy keeps first occurrences and loses no distinct key"
          <|
            \items ->
                let
                    unique : List ( Int, Int )
                    unique =
                        ListExtra.uniqueBy Tuple.first items

                    inputKeys : List Int
                    inputKeys =
                        List.map Tuple.first items

                    outputKeys : List Int
                    outputKeys =
                        List.map Tuple.first unique

                    firstForKey : Int -> Maybe ( Int, Int )
                    firstForKey key =
                        items
                            |> List.filter (\( itemKey, _ ) -> itemKey == key)
                            |> List.head
                in
                Expect.all
                    [ \_ ->
                        List.all
                            (\( key, value ) -> firstForKey key == Just ( key, value ))
                            unique
                            |> Expect.equal True
                    , \_ ->
                        List.all (\key -> List.member key outputKeys) inputKeys
                            |> Expect.equal True
                    ]
                    ()
        , fuzz okValues
            "combineErrors preserves Ok values in order (including the empty list)"
          <|
            \values ->
                let
                    results : List (Result String Int)
                    results =
                        List.map Ok values
                in
                ListExtra.combineErrors results
                    |> Expect.equal (Ok values)
        , fuzz leftmostErrorCase "combineErrors returns the leftmost error" <|
            \( prefix, error, suffix ) ->
                List.map Ok prefix
                    ++ [ Err error ]
                    ++ suffix
                    |> ListExtra.combineErrors
                    |> Expect.equal (Err error)
        ]


indexedList : Fuzzer ( Int, List Int )
indexedList =
    Fuzz.listOfLengthBetween 0 32 itemFuzzer
        |> Fuzz.andThen
            (\items ->
                Fuzz.intRange -2 (List.length items + 2)
                    |> Fuzz.map (\index -> ( index, items ))
            )


outOfRangeIndexedList : Fuzzer ( Int, List Int )
outOfRangeIndexedList =
    Fuzz.listOfLengthBetween 0 32 itemFuzzer
        |> Fuzz.andThen
            (\items ->
                Fuzz.oneOf
                    [ Fuzz.intRange -100 -1
                    , Fuzz.intRange (List.length items) (List.length items + 100)
                    ]
                    |> Fuzz.map (\index -> ( index, items ))
            )


inRangeIndexedList : Fuzzer ( Int, List Int )
inRangeIndexedList =
    Fuzz.listOfLengthBetween 1 32 itemFuzzer
        |> Fuzz.andThen
            (\items ->
                Fuzz.intRange 0 (List.length items - 1)
                    |> Fuzz.map (\index -> ( index, items ))
            )


itemFuzzer : Fuzzer Int
itemFuzzer =
    Fuzz.intRange 0 100


okValues : Fuzzer (List Int)
okValues =
    Fuzz.frequency
        [ ( 1, Fuzz.constant [] )
        , ( 3, Fuzz.listOfLengthBetween 1 32 itemFuzzer )
        ]


change : Int -> Int
change value =
    value + 1000000


valueAt : Int -> List a -> Maybe a
valueAt index items =
    items
        |> List.drop index
        |> List.head


uniqueKeyedList : Fuzzer (List ( Int, Int ))
uniqueKeyedList =
    Fuzz.listOfLengthBetween 0
        32
        (Fuzz.pair (Fuzz.intRange 0 5) (Fuzz.intRange 0 1000))


leftmostErrorCase : Fuzzer ( List Int, String, List (Result String Int) )
leftmostErrorCase =
    Fuzz.map3
        (\prefix error suffix -> ( prefix, error, suffix ))
        (Fuzz.listOfLengthBetween 0 8 itemFuzzer)
        Fuzz.string
        (Fuzz.listOfLengthBetween 0 8 (Fuzz.result Fuzz.string itemFuzzer))


isSubsequenceOf : List a -> List a -> Bool
isSubsequenceOf subsequence items =
    case ( subsequence, items ) of
        ( [], _ ) ->
            True

        ( expected :: restExpected, actual :: restActual ) ->
            if expected == actual then
                isSubsequenceOf restExpected restActual

            else
                isSubsequenceOf subsequence restActual

        ( _ :: _, [] ) ->
            False


hasNoDuplicates : List a -> Bool
hasNoDuplicates items =
    List.length items == List.length (List.foldl keepFirst [] items)


keepFirst : a -> List a -> List a
keepFirst item seen =
    if List.member item seen then
        seen

    else
        item :: seen
