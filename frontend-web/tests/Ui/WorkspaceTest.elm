module Ui.WorkspaceTest exposing (tests)

{-| Tests for the workspace windowing decision.

`Ui.Workspace.paneVisibility` decides which panes are on screen without
dropping the off-screen ones, so every pane keeps its DOM node (and with it
its scroll offset) while the user navigates.

-}

import Element exposing (Device, DeviceClass(..), Orientation(..))
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Ui.Workspace as Workspace


device : DeviceClass -> Device
device class =
    { class = class, orientation = Landscape }


tests : Test
tests =
    describe "Ui.Workspace"
        [ visibilityTests
        , renderingTests
        ]


renderingTests : Test
renderingTests =
    let
        rendered : DeviceClass -> Query.Single ()
        rendered class =
            [ ( "diary", Element.text "diary-pane" )
            , ( "food-search", Element.text "search-pane" )
            , ( "food-detail", Element.text "detail-pane" )
            ]
                |> Workspace.view (device class)
                |> Element.layout []
                |> Query.fromHtml
    in
    describe "view"
        [ test "keeps side-by-side panes outside the window in the DOM" <|
            \_ ->
                rendered Desktop
                    |> Query.has [ Selector.text "diary-pane" ]
        , test "hides exactly the panes outside the side-by-side window" <|
            \_ ->
                rendered Desktop
                    |> Query.findAll [ Selector.style "display" "none" ]
                    |> Query.count (Expect.equal 1)
        , test "drops panes outside the window on a phone" <|
            \_ ->
                rendered Phone
                    |> Query.findAll [ Selector.style "display" "none" ]
                    |> Query.count (Expect.equal 0)
        ]


visibilityTests : Test
visibilityTests =
    describe "paneVisibility"
        [ test "phone shows only the last pane" <|
            \_ ->
                Workspace.paneVisibility (device Phone)
                    [ "diary", "search", "food-detail" ]
                    |> Expect.equal
                        [ ( "diary", False )
                        , ( "search", False )
                        , ( "food-detail", True )
                        ]
        , test "desktop shows the last two panes" <|
            \_ ->
                Workspace.paneVisibility (device Desktop)
                    [ "diary", "search", "food-detail" ]
                    |> Expect.equal
                        [ ( "diary", False )
                        , ( "search", True )
                        , ( "food-detail", True )
                        ]
        , test "keeps every pane visible when they fit" <|
            \_ ->
                Workspace.paneVisibility (device Desktop) [ "diary", "search" ]
                    |> Expect.equal [ ( "diary", True ), ( "search", True ) ]
        ]
