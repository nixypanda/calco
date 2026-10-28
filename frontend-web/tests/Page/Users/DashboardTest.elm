module Page.Users.DashboardTest exposing (tests)

{-| The dashboard has no retry message; a remount or refresh is modelled by a
second load completion, which is how Main recovers from a failed request.
-}

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Expect
import Page.Users.Dashboard as AdminDashboard
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.Dashboard"
        [ test "loaded users expose rows and both admin routes open" <|
            \_ ->
                let
                    loaded : AdminDashboard.Model
                    loaded =
                        step (AdminDashboard.UsersLoaded (Ok [ alice, bob ])) loading
                in
                { initOut = Tuple.second AdminDashboard.init
                , rows = (toScreen loaded).rows
                , createOut = out AdminDashboard.NavigateCreateUser loaded
                , editOut = out (AdminDashboard.NavigateEditUser "u1") loaded
                }
                    |> Expect.equal
                        { initOut = AdminDashboard.RequestUsers
                        , rows = expectedRows
                        , createOut = AdminDashboard.Navigate AdminCreateUser
                        , editOut = AdminDashboard.Navigate (AdminEditUser "u1")
                        }
        , test "a failed load retries, create opens, then a 401 on refresh expires" <|
            \_ ->
                let
                    failed : AdminDashboard.Model
                    failed =
                        step (AdminDashboard.UsersLoaded (Err Client.NetworkError)) loading

                    retried : AdminDashboard.Model
                    retried =
                        step (AdminDashboard.UsersLoaded (Ok [ alice, bob ])) failed
                in
                { failedError = (toScreen failed).error
                , retriedRows = (toScreen retried).rows
                , createOut = out AdminDashboard.NavigateCreateUser retried
                , finalOut =
                    out
                        (AdminDashboard.UsersLoaded (Err Fixtures.unauthorized))
                        retried
                , finalRows =
                    (toScreen
                        (step
                            (AdminDashboard.UsersLoaded (Err Fixtures.unauthorized))
                            retried
                        )
                    ).rows
                }
                    |> Expect.equal
                        { failedError = Just Fixtures.networkErrorMessage
                        , retriedRows = expectedRows
                        , createOut = AdminDashboard.Navigate AdminCreateUser
                        , finalOut = AdminDashboard.SessionExpired
                        , finalRows = expectedRows
                        }
        ]



-- SCREEN PROJECTION


type alias Row =
    { username : String, displayName : String, status : String }


type alias Screen =
    { rows : List Row
    , error : Maybe String
    }


toScreen : AdminDashboard.Model -> Screen
toScreen model =
    case model of
        AdminDashboard.Loading ->
            { rows = [], error = Nothing }

        AdminDashboard.LoadFailed error ->
            { rows = [], error = Just (Client.displayError error) }

        AdminDashboard.Loaded users ->
            { rows = List.map row users, error = Nothing }


row : User -> Row
row user =
    { username = user.username
    , displayName = user.displayName
    , status = user.status
    }



-- HELPERS


loading : AdminDashboard.Model
loading =
    Tuple.first AdminDashboard.init


step : AdminDashboard.Msg -> AdminDashboard.Model -> AdminDashboard.Model
step msg model =
    Fixtures.tupleFirst (AdminDashboard.update msg model)


out : AdminDashboard.Msg -> AdminDashboard.Model -> AdminDashboard.OutMsg
out msg model =
    Fixtures.tupleThird (AdminDashboard.update msg model)


expectedRows : List Row
expectedRows =
    [ { username = "alice", displayName = "Alice", status = "active" }
    , { username = "bob", displayName = "Bob", status = "disabled" }
    ]


alice : User
alice =
    { id = "u1"
    , username = "alice"
    , displayName = "Alice"
    , status = "active"
    , createdAt = "2026-06-04"
    }


bob : User
bob =
    { id = "u2"
    , username = "bob"
    , displayName = "Bob"
    , status = "disabled"
    , createdAt = "2026-06-05"
    }
