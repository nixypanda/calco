module AdminDashboardTest exposing (tests)

import Api.Client as Client
import Data.User as User
import Expect
import Lib.Loadable exposing (Loadable(..))
import Page.Admin.Dashboard as Admin
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Admin.Dashboard"
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
        , test "reset password payload uses selected user" <|
            \_ ->
                { initialModel | resetForm = Just { userId = "u1", password = "new-password" } }
                    |> Admin.resetPasswordPayload
                    |> Expect.equal (Ok ( "u1", { newPassword = "new-password" } ))
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
                    |> Admin.update
                        (Admin.EnableCompleted
                            (Err (Client.BadStatus 500 "boom" "Failed"))
                        )
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "boom: Failed")
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


firstOfThree : ( a, b, c ) -> a
firstOfThree ( first, _, _ ) =
    first


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, third ) =
    third
