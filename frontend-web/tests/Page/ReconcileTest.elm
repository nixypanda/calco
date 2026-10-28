module Page.ReconcileTest exposing (tests)

{-| Laws for `Page.reconcile` stated over plain pane records, not over page
internals. Desired keys are deduped locally so every property can assume the
uniqueness the page layer also assumes.
-}

import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Page
import Test exposing (Test, describe, fuzz2)


type alias Pane =
    { key : String, marker : Int }


type alias Desired =
    { key : String }


newMarker : Int
newMarker =
    0


tests : Test
tests =
    describe "Page.reconcile"
        [ panesFollowDesiredOrder
        , reusesExistingPanes
        , initializesOnlyMissingKeys
        , isIdempotent
        ]


panesFollowDesiredOrder : Test
panesFollowDesiredOrder =
    fuzz2 existingPanes
        desiredPanes
        "output panes follow the desired order"
        (\existing desired ->
            reconcilePanes existing desired
                |> .panes
                |> List.map .key
                |> Expect.equal (List.map .key desired)
        )


reusesExistingPanes : Test
reusesExistingPanes =
    fuzz2 existingPanes
        desiredPanes
        "existing panes with matching keys are reused unchanged"
        (\existing desired ->
            let
                result : ReconcileResult
                result =
                    reconcilePanes existing desired

                desiredKeys : List String
                desiredKeys =
                    List.map .key desired
            in
            existing
                |> List.filter (\pane -> List.member pane.key desiredKeys)
                |> List.map
                    (\pane ->
                        paneFor pane.key result.panes
                            |> Expect.equal (Just pane)
                            |> Expect.onFail ("expected reused pane " ++ pane.key)
                    )
                |> expectAll
        )


initializesOnlyMissingKeys : Test
initializesOnlyMissingKeys =
    fuzz2 existingPanes
        desiredPanes
        "effects and initialized keys cover exactly the missing desired keys"
        (\existing desired ->
            let
                result : ReconcileResult
                result =
                    reconcilePanes existing desired

                missing : List String
                missing =
                    missingDesiredKeys existing desired
            in
            Expect.all
                [ \_ -> result.effects |> Expect.equal missing
                , \_ -> result.initializedKeys |> Expect.equal missing
                , \_ ->
                    missing
                        |> List.map (\key -> paneFor key result.panes)
                        |> List.map (Maybe.map .marker)
                        |> Expect.equal (List.map (always (Just newMarker)) missing)
                ]
                ()
        )


isIdempotent : Test
isIdempotent =
    fuzz2 existingPanes
        desiredPanes
        "reconciling its own output produces no effects and keeps the panes"
        (\existing desired ->
            let
                firstResult : ReconcileResult
                firstResult =
                    reconcilePanes existing desired

                secondResult : ReconcileResult
                secondResult =
                    reconcilePanes firstResult.panes desired
            in
            Expect.all
                [ \_ -> secondResult.panes |> Expect.equal firstResult.panes
                , \_ -> secondResult.effects |> Expect.equal []
                , \_ -> secondResult.initializedKeys |> Expect.equal []
                ]
                ()
        )


type alias ReconcileResult =
    { panes : List Pane
    , effects : List String
    , initializedKeys : List String
    }


reconcilePanes : List Pane -> List Desired -> ReconcileResult
reconcilePanes existing desired =
    Page.reconcile .key .key initialize existing desired


initialize : Desired -> ( Pane, String )
initialize desired =
    ( { key = desired.key, marker = newMarker }, desired.key )


paneFor : String -> List Pane -> Maybe Pane
paneFor key panes =
    panes
        |> List.filter (\pane -> pane.key == key)
        |> List.head


missingDesiredKeys : List Pane -> List Desired -> List String
missingDesiredKeys existing desired =
    let
        existingKeys : List String
        existingKeys =
            List.map .key existing
    in
    desired
        |> List.filter (\pane -> not (List.member pane.key existingKeys))
        |> List.map .key


existingPanes : Fuzzer (List Pane)
existingPanes =
    uniqueKeys
        |> Fuzz.map
            (List.indexedMap
                (\index key -> { key = key, marker = index + 1 })
            )


desiredPanes : Fuzzer (List Desired)
desiredPanes =
    uniqueKeys
        |> Fuzz.map (List.map (\key -> { key = key }))


uniqueKeys : Fuzzer (List String)
uniqueKeys =
    Fuzz.list (Fuzz.intRange 0 1000)
        |> Fuzz.map (List.map String.fromInt >> dedupe)


dedupe : List String -> List String
dedupe values =
    List.foldl
        (\value kept ->
            if List.member value kept then
                kept

            else
                kept ++ [ value ]
        )
        []
        values


expectAll : List Expectation -> Expectation
expectAll expectations =
    case expectations of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map (\expectation _ -> expectation) expectations) ()
