module Page.BusyTest exposing (tests)

{-| `Page.isBusy` is the page-root marker's source of truth. It must cover the
date gate and page-level initial loads, while excluding settled failures.
-}

import Api.Client as Client
import Data.Route exposing (Route(..))
import Expect
import Page
import Page.Users.Dashboard as AdminDashboard
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.isBusy"
        [ test "is busy while waiting for today" <|
            \_ ->
                Page.init { route = DiaryDay Nothing Nothing, today = Nothing }
                    |> Fixtures.tupleFirst
                    |> Page.isBusy
                    |> Expect.equal True
        , test "a P1 page is busy while loading, and settled after loaded or failed" <|
            \_ ->
                let
                    loading : Page.Model
                    loading =
                        pageFor AdminDashboard

                    loaded : Page.Model
                    loaded =
                        apply
                            (Page.GotAdminMsg (AdminDashboard.UsersLoaded (Ok [])))
                            loading

                    failed : Page.Model
                    failed =
                        apply
                            (Page.GotAdminMsg
                                (AdminDashboard.UsersLoaded (Err Client.NetworkError))
                            )
                            loading
                in
                Expect.all
                    [ \_ -> Page.isBusy loading |> Expect.equal True
                    , \_ -> Page.isBusy loaded |> Expect.equal False
                    , \_ -> Page.isBusy failed |> Expect.equal False
                    ]
                    ()
        ]


pageFor : Route -> Page.Model
pageFor route =
    Page.init { route = route, today = Nothing }
        |> Fixtures.tupleFirst


apply : Page.Msg -> Page.Model -> Page.Model
apply msg model =
    case Page.update { route = AdminDashboard, today = Nothing } msg model of
        Just ( next, _, _ ) ->
            next

        Nothing ->
            model
