module AccessTest exposing (tests)

import Access exposing (RouteDecision(..))
import Data.Auth as Auth
import Data.Route exposing (Route(..))
import Expect
import Session exposing (Session(..))
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Access.resolveRoute"
        [ test "root redirects to setup when no admin exists" <|
            \_ ->
                Access.resolveRoute Unauthenticated False Root
                    |> Expect.equal (Navigate BootstrapSetup)
        , test "root redirects to login when signed out and admin exists" <|
            \_ ->
                Access.resolveRoute Unauthenticated True Root
                    |> Expect.equal (Navigate AuthLogin)
        , test "root redirects to admin for admin identity" <|
            \_ ->
                Access.resolveRoute admin True Root
                    |> Expect.equal (Navigate AdminDashboard)
        , test "root redirects to home for normal user" <|
            \_ ->
                Access.resolveRoute normalUser True Root
                    |> Expect.equal (Navigate (DiaryDay Nothing))
        , test "food routes reject signed-out users" <|
            \_ ->
                Access.resolveRoute Unauthenticated True (FoodSearch Nothing)
                    |> Expect.equal (Navigate AuthLogin)
        , test "food routes reject admins" <|
            \_ ->
                Access.resolveRoute admin True (FoodSearch Nothing)
                    |> Expect.equal (Navigate AdminDashboard)
        , test "admin route rejects normal users" <|
            \_ ->
                Access.resolveRoute normalUser True AdminDashboard
                    |> Expect.equal (Navigate (DiaryDay Nothing))
        , test "Loading session holds for Root when admin exists" <|
            \_ ->
                Access.resolveRoute Loading True Root
                    |> Expect.equal Hold
        , test "Loading session holds for Diary when admin exists" <|
            \_ ->
                Access.resolveRoute Loading True (DiaryDay Nothing)
                    |> Expect.equal Hold
        , test "Loading session holds when no admin exists" <|
            \_ ->
                Access.resolveRoute Loading False Root
                    |> Expect.equal Hold
        ]


admin : Session
admin =
    Authenticated { id = "1", username = "admin", role = Auth.Admin }


normalUser : Session
normalUser =
    Authenticated { id = "2", username = "user", role = Auth.User }
