module Page.Users.DashboardTest exposing (tests)

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Expect
import Page.Users.Dashboard as AdminDashboard
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.Dashboard"
        [ test "a user loads users and opens create" <|
            \_ ->
                Story.start AdminDashboard.init
                    |> step (AdminDashboard.UsersLoaded (Ok [ alice, bob ]))
                    |> step AdminDashboard.NavigateCreateUser
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (AdminDashboard.Navigate AdminCreateUser)
                        )
        , test "a failed load retries and a 401 expires" <|
            \_ ->
                Story.start AdminDashboard.init
                    |> step (AdminDashboard.UsersLoaded (Err Client.NetworkError))
                    |> step (AdminDashboard.UsersLoaded (Ok [ alice, bob ]))
                    |> step (AdminDashboard.UsersLoaded (Err Fixtures.unauthorized))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal AdminDashboard.SessionExpired
                        )
        ]


stepWithOut :
    AdminDashboard.Msg
    -> AdminDashboard.Model
    -> ( AdminDashboard.Model, AdminDashboard.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            AdminDashboard.update msg model
    in
    ( next, outMsg )


-- STORY PIPELINE


type alias Journey =
    Story.Journey AdminDashboard.Model AdminDashboard.OutMsg


step : AdminDashboard.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( AdminDashboard.Model, AdminDashboard.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


alice : User
alice =
    user "u1" "alice" "Alice" "active"


bob : User
bob =
    user "u2" "bob" "Bob" "inactive"


user : String -> String -> String -> String -> User
user id username displayName status =
    { id = id
    , username = username
    , displayName = displayName
    , status = status
    , createdAt = "2026-01-01T00:00:00Z"
    }
