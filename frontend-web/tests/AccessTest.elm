module AccessTest exposing (tests)

import Access exposing (RouteDecision(..))
import Data.Auth as Auth
import Expect
import Route exposing (Route(..))
import Session
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Access.resolveRoute"
        [ test "root redirects to setup when no admin exists" <|
            \_ ->
                { signedOut | adminExists = False }
                    |> (\session -> Access.resolveRoute session Root)
                    |> Expect.equal (Navigate Setup)
        , test "root redirects to login when signed out and admin exists" <|
            \_ ->
                signedOut
                    |> (\session -> Access.resolveRoute session Root)
                    |> Expect.equal (Navigate Login)
        , test "root redirects to admin for admin identity" <|
            \_ ->
                admin
                    |> (\session -> Access.resolveRoute session Root)
                    |> Expect.equal (Navigate AdminDashboard)
        , test "root redirects to home for normal user" <|
            \_ ->
                normalUser
                    |> (\session -> Access.resolveRoute session Root)
                    |> Expect.equal (Navigate (Diary Nothing))
        , test "food routes reject signed-out users" <|
            \_ ->
                signedOut
                    |> (\session -> Access.resolveRoute session (FoodSearch Nothing))
                    |> Expect.equal (Navigate Login)
        , test "food routes reject admins" <|
            \_ ->
                admin
                    |> (\session -> Access.resolveRoute session (FoodSearch Nothing))
                    |> Expect.equal (Navigate AdminDashboard)
        , test "admin route rejects normal users" <|
            \_ ->
                normalUser
                    |> (\session -> Access.resolveRoute session AdminDashboard)
                    |> Expect.equal (Navigate (Diary Nothing))
        ]


signedOut : Session.Session
signedOut =
    let
        base : Session.Session
        base =
            Session.init
    in
    { base | state = Session.Loaded }


admin : Session.Session
admin =
    { signedOut | identity = Just { id = "1", username = "admin", role = Auth.Admin } }


normalUser : Session.Session
normalUser =
    { signedOut | identity = Just { id = "2", username = "user", role = Auth.User } }
