module Ui.SkeletonTest exposing (tests)

{-| Allowed render exception: this is an ARIA contract test, not a DOM/CSS test.
`Skeleton.busy` must expose one status, announce its hidden label, hide the
decorative subtree from assistive technology, and contain no focusable
elements. Those outcomes only exist after rendering; the browser harness owns
the layout and marker assertions.
-}

import Element
import Expect
import Html.Attributes as Attr
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Ui.Skeleton as Skeleton
import Ui.Theme as Theme


tests : Test
tests =
    describe "Ui.Skeleton.busy"
        [ test "exposes one announced status with no focusable descendants" <|
            \_ ->
                let
                    root : Query.Single Never
                    root =
                        Skeleton.busy
                            { label = "Loading" }
                            [ Skeleton.elLine Theme.light
                                { size = 24, width = Element.fill }
                            ]
                            |> Element.layout []
                            |> Query.fromHtml

                    status : Query.Single Never
                    status =
                        Query.find
                            [ Selector.attribute (Attr.attribute "role" "status") ]
                            root
                in
                Expect.all
                    [ \_ ->
                        Query.findAll
                            [ Selector.attribute (Attr.attribute "role" "status") ]
                            root
                            |> Query.count (Expect.equal 1)
                    , \_ ->
                        status
                            |> Query.has [ Selector.text "Loading" ]
                    , \_ ->
                        Query.findAll
                            [ Selector.attribute (Attr.attribute "aria-hidden" "true") ]
                            root
                            |> Query.count (Expect.equal 1)
                    , \_ ->
                        status
                            |> Query.hasNot
                                [ Selector.attribute (Attr.attribute "aria-busy" "true") ]
                    , \_ ->
                        status
                            |> Query.hasNot
                                [ Selector.attribute (Attr.attribute "aria-busy" "false") ]
                    , \_ -> noFocusable root
                    ]
                    ()
        ]


noFocusable : Query.Single msg -> Expect.Expectation
noFocusable root =
    Expect.all
        (List.map
            (\tag ->
                \_ ->
                    Query.findAll [ Selector.tag tag ] root
                        |> Query.count (Expect.equal 0)
            )
            [ "button", "a", "input", "select", "textarea" ]
        )
        ()
