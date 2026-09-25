module Page.Users.DashboardTest exposing (tests)

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Expect
import Page.Users.Dashboard as AdminDashboard
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Unauthorized"


tests : Test
tests =
    describe "Page.Users.Dashboard"
        [ test "loading the user list requests users and renders one row per user" <|
            \_ ->
                let
                    ( loading, request ) =
                        AdminDashboard.init

                    loaded : AdminDashboard.Model
                    loaded =
                        step (AdminDashboard.UsersLoaded (Ok [ alice, bob ])) loading
                in
                { request = request
                , loading = toScreen loading |> .phase
                , loaded = toScreen loaded
                }
                    |> Expect.equal
                        { request = AdminDashboard.RequestUsers
                        , loading = "loading"
                        , loaded =
                            { phase = "loaded"
                            , rows =
                                [ { username = "alice"
                                  , displayName = "Alice"
                                  , status = "active"
                                  }
                                , { username = "bob"
                                  , displayName = "Bob"
                                  , status = "disabled"
                                  }
                                ]
                            , error = Nothing
                            }
                        }
        , test "a failed load shows an error and an unauthorized load expires the session" <|
            \_ ->
                let
                    loading : AdminDashboard.Model
                    loading =
                        Tuple.first AdminDashboard.init
                in
                { failed =
                    toScreen
                        (step (AdminDashboard.UsersLoaded (Err Client.NetworkError)) loading)
                , unauthorized = out (AdminDashboard.UsersLoaded (Err unauthorized)) loading
                }
                    |> Expect.equal
                        { failed = { phase = "failed", rows = [], error = Just networkErrorMessage }
                        , unauthorized = AdminDashboard.SessionExpired
                        }
        , test "a row opens the edit page and the create action opens the create page" <|
            \_ ->
                let
                    loading : AdminDashboard.Model
                    loading =
                        Tuple.first AdminDashboard.init
                in
                { edit = out (AdminDashboard.NavigateEditUser "u1") loading
                , create = out AdminDashboard.NavigateCreateUser loading
                }
                    |> Expect.equal
                        { edit = AdminDashboard.Navigate (AdminEditUser "u1")
                        , create = AdminDashboard.Navigate AdminCreateUser
                        }
        ]



-- SCREEN PROJECTION


type alias Row =
    { username : String, displayName : String, status : String }


type alias Screen =
    { phase : String
    , rows : List Row
    , error : Maybe String
    }


toScreen : AdminDashboard.Model -> Screen
toScreen model =
    case model of
        AdminDashboard.Loading ->
            { phase = "loading", rows = [], error = Nothing }

        AdminDashboard.LoadFailed error ->
            { phase = "failed"
            , rows = []
            , error = Just (Client.displayError error)
            }

        AdminDashboard.Loaded users ->
            { phase = "loaded"
            , rows = List.map row users
            , error = Nothing
            }


row : User -> Row
row user =
    { username = user.username
    , displayName = user.displayName
    , status = user.status
    }



-- HELPERS


step : AdminDashboard.Msg -> AdminDashboard.Model -> AdminDashboard.Model
step msg model =
    first (AdminDashboard.update msg model)


out : AdminDashboard.Msg -> AdminDashboard.Model -> AdminDashboard.OutMsg
out msg model =
    third (AdminDashboard.update msg model)


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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
