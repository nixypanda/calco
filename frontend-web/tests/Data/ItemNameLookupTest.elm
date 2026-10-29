module Data.ItemNameLookupTest exposing (tests)

import Data.ItemNameLookup as ItemNameLookup exposing (Names)
import Expect
import Fuzz exposing (Fuzzer)
import Test exposing (Test, describe, fuzz)


tests : Test
tests =
    describe "Data.ItemNameLookup"
        [ fuzz lookupFuzzer
            "nextMissingProductId is the first unique, unloaded, non-completed id"
          <|
            \( completed, ids, loaded ) ->
                ItemNameLookup.nextMissingProductId completed ids (namesFrom loaded)
                    |> Expect.equal (firstEligible completed ids loaded)
        ]


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


namesFrom : List String -> Names
namesFrom ids =
    List.foldl
        (\id names -> ItemNameLookup.insertProduct id id names)
        ItemNameLookup.empty
        ids


firstEligible : Maybe String -> List String -> List String -> Maybe String
firstEligible completed ids loaded =
    ids
        |> firstUnique
        |> List.filter
            (\id -> Just id /= completed && not (List.member id loaded))
        |> List.head


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
