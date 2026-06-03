module AdminDashboardTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Data.User as User
import Expect
import Loadable exposing (Loadable(..))
import Page.AdminDashboard as Admin
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.AdminDashboard"
        [ test "init starts with users loading" <|
            \_ ->
                Admin.init
                    |> Tuple.first
                    |> .users
                    |> Expect.equal Loading
        , test "init requests users" <|
            \_ ->
                Admin.init
                    |> Tuple.second
                    |> Expect.equal Admin.RequestUsers
        , test "user load success stores users" <|
            \_ ->
                initialModel
                    |> Admin.update (Admin.UsersLoaded (Ok [ user ]))
                    |> firstOfThree
                    |> .users
                    |> Expect.equal (Success [ user ])
        , test "create payload trims username and display name" <|
            \_ ->
                { initialModel | createForm = { username = " alice ", displayName = " Alice ", initialPassword = "secret" } }
                    |> Admin.createUserPayload
                    |> Expect.equal (Ok { username = "alice", displayName = "Alice", initialPassword = "secret" })
        , test "reset password payload uses selected user" <|
            \_ ->
                { initialModel | resetForm = Just { userId = "u1", password = "new-password" } }
                    |> Admin.resetPasswordPayload
                    |> Expect.equal (Ok ( "u1", { newPassword = "new-password" } ))
        , test "create success clears form and requests reload" <|
            \_ ->
                { initialModel | showCreate = True, createForm = { username = "alice", displayName = "Alice", initialPassword = "secret" } }
                    |> Admin.update (Admin.CreateCompleted (Ok loginSession))
                    |> thirdOfThree
                    |> Expect.equal Admin.RequestUsers
        , test "create failure preserves existing users" <|
            \_ ->
                { initialModel | users = Success [ user ] }
                    |> Admin.update (Admin.CreateCompleted (Err (Client.BadStatus 400 "bad" "Bad request")))
                    |> firstOfThree
                    |> .users
                    |> Expect.equal (Success [ user ])
        , test "reset success clears reset form" <|
            \_ ->
                { initialModel | resetForm = Just { userId = "u1", password = "new-password" } }
                    |> Admin.update (Admin.ResetCompleted (Ok ()))
                    |> firstOfThree
                    |> .resetForm
                    |> Expect.equal Nothing
        , test "disable success requests reload" <|
            \_ ->
                initialModel
                    |> Admin.update (Admin.DisableCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal Admin.RequestUsers
        , test "enable failure preserves users and stores error" <|
            \_ ->
                { initialModel | users = Success [ user ] }
                    |> Admin.update (Admin.EnableCompleted (Err (Client.BadStatus 500 "boom" "Failed")))
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "boom: Failed")
        , test "loadable not-asked state exists" <|
            \_ ->
                let
                    expected : Loadable Client.ApiError (List User.User)
                    expected =
                        NotAsked
                in
                NotAsked
                    |> Expect.equal expected
        ]


initialModel : Admin.Model
initialModel =
    Admin.init |> Tuple.first


user : User.User
user =
    { id = "u1"
    , username = "alice"
    , displayName = "Alice"
    , status = "active"
    , createdAt = "2026-06-04"
    }


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }


firstOfThree : ( a, b, c ) -> a
firstOfThree ( first, _, _ ) =
    first


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, third ) =
    third
