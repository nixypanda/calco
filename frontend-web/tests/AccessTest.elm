module AccessTest exposing (tests)

import Access exposing (RouteDecision(..))
import Data.Auth as Auth exposing (Session(..))
import Data.Route exposing (Route(..))
import Expect
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
                    |> Expect.equal (Navigate (DiaryDay Nothing Nothing))
        , test "food routes reject signed-out users" <|
            \_ ->
                Access.resolveRoute Unauthenticated True (FoodSearch Nothing Nothing)
                    |> Expect.equal (Navigate AuthLogin)
        , test "food routes reject admins" <|
            \_ ->
                Access.resolveRoute admin True (FoodSearch Nothing Nothing)
                    |> Expect.equal (Navigate AdminDashboard)
        , test "admin route rejects normal users" <|
            \_ ->
                Access.resolveRoute normalUser True AdminDashboard
                    |> Expect.equal (Navigate (DiaryDay Nothing Nothing))
        , test "goal settings route allows authenticated users" <|
            \_ ->
                Access.resolveRoute normalUser True GoalSettings
                    |> Expect.equal (Render GoalSettings)
        , test "goal settings route rejects signed-out users" <|
            \_ ->
                Access.resolveRoute Unauthenticated True GoalSettings
                    |> Expect.equal (Navigate AuthLogin)
        , test "goal settings route rejects admins" <|
            \_ ->
                Access.resolveRoute admin True GoalSettings
                    |> Expect.equal (Navigate AdminDashboard)
        , test "API key settings allows authenticated users" <|
            \_ ->
                Access.resolveRoute normalUser True SettingsApiKeys
                    |> Expect.equal (Render SettingsApiKeys)
        , test "API key settings rejects signed-out users" <|
            \_ ->
                Access.resolveRoute Unauthenticated True SettingsApiKeys
                    |> Expect.equal (Navigate AuthLogin)
        , test "API key settings rejects admins" <|
            \_ ->
                Access.resolveRoute admin True SettingsApiKeys
                    |> Expect.equal (Navigate AdminDashboard)
        , test "API key creation allows authenticated users" <|
            \_ ->
                Access.resolveRoute normalUser True SettingsApiKeyCreate
                    |> Expect.equal (Render SettingsApiKeyCreate)
        , test "API key creation rejects signed-out users" <|
            \_ ->
                Access.resolveRoute Unauthenticated True SettingsApiKeyCreate
                    |> Expect.equal (Navigate AuthLogin)
        , test "API key creation rejects admins" <|
            \_ ->
                Access.resolveRoute admin True SettingsApiKeyCreate
                    |> Expect.equal (Navigate AdminDashboard)
        , test "Loading session holds for Root when admin exists" <|
            \_ ->
                Access.resolveRoute Loading True Root
                    |> Expect.equal Hold
        ]


admin : Session
admin =
    Authenticated { id = "1", username = "admin", role = Auth.Admin }


normalUser : Session
normalUser =
    Authenticated { id = "2", username = "user", role = Auth.User }
