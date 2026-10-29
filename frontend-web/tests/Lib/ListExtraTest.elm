module Lib.ListExtraTest exposing (tests)

import Expect
import Fuzz exposing (Fuzzer)
import Lib.ListExtra as ListExtra
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Lib.ListExtra"
        [ fuzz indexedList
            "updateAt changes only an in-range target and never changes length"
          <|
            \( index, items ) ->
                if index >= 0 && index < List.length items then
                    let
                        updated : List Int
                        updated =
                            ListExtra.updateAt index change items
                    in
                    Expect.all
                        [ \_ -> List.length updated |> Expect.equal (List.length items)
                        , \_ -> List.take index updated |> Expect.equal (List.take index items)
                        , \_ ->
                            List.drop (index + 1) updated
                                |> Expect.equal (List.drop (index + 1) items)
                        , \_ ->
                            valueAt index updated
                                |> Expect.equal (Maybe.map change (valueAt index items))
                        ]
                        ()

                else
                    ListExtra.updateAt index change items |> Expect.equal items
        , fuzz indexedList "removeAt removes only an in-range target and preserves order" <|
            \( index, items ) ->
                if index >= 0 && index < List.length items then
                    let
                        removed : List Int
                        removed =
                            ListExtra.removeAt index items
                    in
                    Expect.all
                        [ \_ -> List.length removed |> Expect.equal (List.length items - 1)
                        , \_ -> List.take index removed |> Expect.equal (List.take index items)
                        , \_ ->
                            List.drop index removed |> Expect.equal (List.drop (index + 1) items)
                        ]
                        ()

                else
                    ListExtra.removeAt index items |> Expect.equal items
        , fuzz uniqueKeyedList "uniqueBy keeps first occurrences in input order" <|
            \items ->
                ListExtra.uniqueBy Tuple.first items |> Expect.equal (firstByKey items)
        , fuzz combineCase "combineErrors preserves Ok order and returns the leftmost Err" <|
            \caseValue ->
                ListExtra.combineErrors caseValue.results |> Expect.equal caseValue.expected
        ]


indexedList : Fuzzer ( Int, List Int )
indexedList =
    Fuzz.listOfLengthBetween 0 32 (Fuzz.intRange 0 100)
        |> Fuzz.andThen
            (\items ->
                Fuzz.intRange -2 (List.length items + 2) |> Fuzz.map (\index -> ( index, items ))
            )


change : Int -> Int
change value =
    value + 1000000


valueAt : Int -> List a -> Maybe a
valueAt index items =
    items |> List.drop index |> List.head


uniqueKeyedList : Fuzzer (List ( Int, Int ))
uniqueKeyedList =
    Fuzz.listOfLengthBetween 0 32 (Fuzz.pair (Fuzz.intRange 0 5) (Fuzz.intRange 0 1000))


firstByKey : List ( Int, Int ) -> List ( Int, Int )
firstByKey items =
    List.foldl
        (\item unique ->
            if List.any (\( key, _ ) -> key == Tuple.first item) unique then
                unique

            else
                unique ++ [ item ]
        )
        []
        items


type alias CombineCase =
    { results : List (Result String Int), expected : Result String (List Int) }


combineCase : Fuzzer CombineCase
combineCase =
    Fuzz.oneOf
        [ Fuzz.map (\values -> { results = List.map Ok values, expected = Ok values })
            (Fuzz.frequency
                [ ( 1, Fuzz.constant [] )
                , ( 3, Fuzz.listOfLengthBetween 1 32 (Fuzz.intRange 0 100) )
                ]
            )
        , Fuzz.map3
            (\prefix error suffix ->
                { results = List.map Ok prefix ++ [ Err error ] ++ suffix
                , expected = Err error
                }
            )
            (Fuzz.listOfLengthBetween 0 8 (Fuzz.intRange 0 100))
            Fuzz.string
            (Fuzz.listOfLengthBetween 0 8 (Fuzz.result Fuzz.string (Fuzz.intRange 0 100)))
        ]
