module Data.ItemNameLookupTest exposing (tests)

import Data.ItemNameLookup as ItemNameLookup exposing (Names)
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.ItemNameLookup"
        [ describe "uniqueProductIds"
            [ fuzz idsFuzzer "keeps first occurrences in input order" <|
                \ids ->
                    ItemNameLookup.uniqueProductIds ids
                        |> Expect.equal (firstUnique ids)
            , fuzz idsFuzzer "is idempotent" <|
                \ids ->
                    ItemNameLookup.uniqueProductIds (ItemNameLookup.uniqueProductIds ids)
                        |> Expect.equal (ItemNameLookup.uniqueProductIds ids)
            , fuzz idsFuzzer "contains no duplicate ids" <|
                \ids ->
                    let
                        unique : List String
                        unique =
                            ItemNameLookup.uniqueProductIds ids
                    in
                    List.all
                        (\id -> List.length (List.filter ((==) id) unique) == 1)
                        unique
                        |> Expect.equal True
            ]
        , describe "nextMissingProductId"
            [ fuzz lookupFuzzer "returns the first unique unloaded non-completed id" <|
                \( completed, ids, loaded ) ->
                    ItemNameLookup.nextMissingProductId completed ids (namesFrom loaded)
                        |> Expect.equal (firstEligible completed ids loaded)
            , fuzz lookupFuzzer "only returns an id that still needs loading" <|
                \( completed, ids, loaded ) ->
                    case ItemNameLookup.nextMissingProductId completed ids (namesFrom loaded) of
                        Nothing ->
                            Expect.pass

                        Just id ->
                            Expect.all
                                [ \_ -> List.member id ids |> Expect.equal True
                                , \_ -> (Just id /= completed) |> Expect.equal True
                                , \_ ->
                                    ItemNameLookup.isLoaded
                                        (ItemNameLookup.productRef id)
                                        (namesFrom loaded)
                                        |> Expect.equal False
                                ]
                                ()
            , fuzz idsFuzzer "without loaded names selects the first input id" <|
                \ids ->
                    ItemNameLookup.nextMissingProductId Nothing ids ItemNameLookup.empty
                        |> Expect.equal (List.head ids)
            , fuzz idsFuzzer "returns Nothing when every id is loaded" <|
                \ids ->
                    ItemNameLookup.nextMissingProductId Nothing ids (namesFrom ids)
                        |> Expect.equal Nothing
            , test "skips loaded ids and duplicate suggestions" <|
                \_ ->
                    ItemNameLookup.nextMissingProductId
                        Nothing
                        [ "food-1", "food-2", "food-2" ]
                        (namesFrom [ "food-1" ])
                        |> Expect.equal (Just "food-2")
            ]
        ]



-- Fuzzers


idFuzzer : Fuzzer String
idFuzzer =
    Fuzz.oneOfValues [ "id-0", "id-1", "id-2", "id-3" ]


idsFuzzer : Fuzzer (List String)
idsFuzzer =
    Fuzz.listOfLengthBetween 0 12 idFuzzer


lookupFuzzer : Fuzzer ( Maybe String, List String, List String )
lookupFuzzer =
    Fuzz.map3
        (\ids loadedCandidates completedIndex ->
            let
                completed : Maybe String
                completed =
                    if completedIndex < 0 then
                        Nothing

                    else
                        List.drop completedIndex ids |> List.head

                loaded : List String
                loaded =
                    List.take (modBy 5 (List.length ids + 1)) ids ++ loadedCandidates
            in
            ( completed, ids, loaded )
        )
        idsFuzzer
        idsFuzzer
        (Fuzz.intRange -1 12)



-- References


namesFrom : List String -> Names
namesFrom ids =
    List.foldl
        (\id names -> ItemNameLookup.insertProduct id id names)
        ItemNameLookup.empty
        ids


firstUnique : List String -> List String
firstUnique ids =
    List.foldl
        (\id unique ->
            if List.member id unique then
                unique

            else
                unique ++ [ id ]
        )
        []
        ids


firstEligible : Maybe String -> List String -> List String -> Maybe String
firstEligible completed ids loaded =
    firstUnique ids
        |> List.filter
            (\id ->
                Just id /= completed && not (List.member id loaded)
            )
        |> List.head
