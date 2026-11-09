module Page.BootShellTest exposing (tests)

{-| Allowed render exception: these are ARIA contracts for the boot body, not
DOM/CSS assertions. The route shape is pure-tested in `Page.PanePlanTest`; the
workspace and skeleton markers belong to the browser harness.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import Html.Attributes as Attr
import Page
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env)
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page boot view"
        [ test "bootstrapView announces one loading status per planned pane" <|
            \_ ->
                Page.bootstrapView env (DiaryDay (Just Fixtures.today) (Just "2026-07"))
                    |> Element.layout []
                    |> Query.fromHtml
                    |> loadingStatuses 2
        , test "a date-gated Page.view announces one loading status" <|
            \_ ->
                let
                    route : Route
                    route =
                        DiaryDay Nothing Nothing

                    waiting : Page.Model
                    waiting =
                        Page.init { route = route, today = Nothing }
                            |> Fixtures.tupleFirst
                in
                Page.view env route waiting
                    |> Element.layout []
                    |> Query.fromHtml
                    |> loadingStatuses 1
        , test "the pre-session boot shell announces one loading status" <|
            \_ ->
                Page.bootShell env
                    |> Element.layout []
                    |> Query.fromHtml
                    |> loadingStatuses 1
        ]


loadingStatuses : Int -> Query.Single msg -> Expect.Expectation
loadingStatuses count root =
    Expect.all
        [ \_ ->
            Query.findAll
                [ Selector.attribute (Attr.attribute "role" "status") ]
                root
                |> Query.count (Expect.equal count)
        , \_ ->
            Query.findAll
                [ Selector.attribute (Attr.attribute "role" "status") ]
                root
                |> Query.each (Query.has [ Selector.text "Loading..." ])
        , \_ -> noFocusable root
        ]
        ()


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


env : Env
env =
    { theme = Theme.light
    , device = { class = Element.Desktop, orientation = Element.Landscape }
    , language = EN_US
    }
