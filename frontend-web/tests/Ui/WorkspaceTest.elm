module Ui.WorkspaceTest exposing (tests)

{-| The exact visibility law for `Ui.Workspace.paneVisibility`.

Pane scroll preservation is a browser behavior: panes stay mounted and are
hidden with CSS so their scroll offsets survive navigation. elm-test has no
layout engine, so this test covers only the pure visibility decision.

-}

import Element
import Expect
import Fuzz exposing (Fuzzer)
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz2)
import Ui.Workspace as Workspace


tests : Test
tests =
    describe "Ui.Workspace.paneVisibility"
        [ fuzz2 SupportFuzz.device keyList "panes are visible iff index reaches the pane window" <|
            \device keys ->
                let
                    result : List ( String, Bool )
                    result =
                        Workspace.paneVisibility device keys

                    splitIndex : Int
                    splitIndex =
                        max 0 (List.length keys - paneLimit device.class)

                    expectedVisibility : Int -> Bool
                    expectedVisibility index =
                        index >= splitIndex
                in
                Expect.all
                    [ \_ -> List.map Tuple.first result |> Expect.equal keys
                    , \_ ->
                        result
                            |> List.indexedMap
                                (\index ( _, visible ) ->
                                    visible == expectedVisibility index
                                )
                            |> List.all identity
                            |> Expect.equal True
                    ]
                    ()
        ]


{-| The public pane-limit rule, encoded locally so this test does not read the
implementation-defined helper directly.
-}
paneLimit : Element.DeviceClass -> Int
paneLimit class =
    case class of
        Element.Phone ->
            1

        Element.Tablet ->
            1

        Element.Desktop ->
            2

        Element.BigDesktop ->
            2


keyList : Fuzzer (List String)
keyList =
    Fuzz.list Fuzz.string
