module Ui.WorkspaceTest exposing (tests)

{-| Laws for `Ui.Workspace.paneVisibility`.

Pane scroll preservation is a browser behavior: panes stay mounted and are
hidden with CSS so their scroll offsets survive navigation. elm-test has no
layout engine, so these tests cover only the pure visibility decision.

-}

import Element exposing (Device, DeviceClass(..))
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, fuzz2)
import Ui.Workspace as Workspace


tests : Test
tests =
    describe "Ui.Workspace.paneVisibility"
        [ fuzz2 SupportFuzz.device keyList "output length equals input length" <|
            \device keys ->
                Workspace.paneVisibility device keys
                    |> List.length
                    |> Expect.equal (List.length keys)
        , fuzz2 SupportFuzz.device keyList "keys and order are preserved" <|
            \device keys ->
                Workspace.paneVisibility device keys
                    |> List.map Tuple.first
                    |> Expect.equal keys
        , fuzz2 SupportFuzz.device keyList "shows exactly the last min(paneLimit, length) panes" <|
            \device keys ->
                let
                    visibleCount : Int
                    visibleCount =
                        Workspace.paneVisibility device keys
                            |> List.filter Tuple.second
                            |> List.length
                in
                visibleCount
                    |> Expect.equal (min (paneLimit device.class) (List.length keys))
        , fuzz2 SupportFuzz.device keyList "hidden panes come before visible panes" <|
            \device keys ->
                let
                    pairs : List ( String, Bool )
                    pairs =
                        Workspace.paneVisibility device keys

                    visibleCount : Int
                    visibleCount =
                        List.length (List.filter Tuple.second pairs)

                    splitIndex : Int
                    splitIndex =
                        List.length keys - visibleCount

                    ( prefix, suffix ) =
                        ( List.take splitIndex pairs, List.drop splitIndex pairs )
                in
                Expect.all
                    [ \_ -> List.all (not << Tuple.second) prefix |> Expect.equal True
                    , \_ -> List.all Tuple.second suffix |> Expect.equal True
                    ]
                    ()
        , fuzz fittingKeys "every pane is visible when the list fits the pane limit" <|
            \( device, keys ) ->
                Workspace.paneVisibility device keys
                    |> List.all Tuple.second
                    |> Expect.equal True
        ]


{-| The public pane-limit rule, encoded locally so this test does not read the
implementation-defined helper directly.
-}
paneLimit : DeviceClass -> Int
paneLimit class =
    case class of
        Phone ->
            1

        Tablet ->
            1

        Desktop ->
            2

        BigDesktop ->
            2


keyList : Fuzzer (List String)
keyList =
    Fuzz.list Fuzz.string


fittingKeys : Fuzzer ( Device, List String )
fittingKeys =
    SupportFuzz.device
        |> Fuzz.andThen
            (\device ->
                Fuzz.map (Tuple.pair device)
                    (Fuzz.listOfLengthBetween 0 (paneLimit device.class) Fuzz.string)
            )
