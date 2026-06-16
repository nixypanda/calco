module Page.Users.DashboardTest exposing (tests)

import Api.Client as Client
import Data.Route exposing (Route(..))
import Data.User exposing (User)
import Expect
import Page.Users.Dashboard as Admin
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.Dashboard"
        [ test "init starts with users loading" <|
            \_ ->
                Admin.init
                    |> Tuple.first
                    |> Expect.equal Admin.Loading
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
                    |> Expect.equal (Admin.Loaded [ user ])
        , test "user load failure stores error" <|
            \_ ->
                initialModel
                    |> Admin.update (Admin.UsersLoaded (Err Client.NetworkError))
                    |> firstOfThree
                    |> Expect.equal (Admin.LoadFailed Client.NetworkError)
        , test "NavigateEditUser navigates to AdminEditUser" <|
            \_ ->
                initialModel
                    |> Admin.update (Admin.NavigateEditUser "u1")
                    |> thirdOfThree
                    |> Expect.equal (Admin.Navigate (AdminEditUser "u1"))
        , test "NavigateCreateUser navigates to AdminCreateUser" <|
            \_ ->
                initialModel
                    |> Admin.update Admin.NavigateCreateUser
                    |> thirdOfThree
                    |> Expect.equal (Admin.Navigate AdminCreateUser)
        ]


initialModel : Admin.Model
initialModel =
    Admin.init |> Tuple.first


user : User
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
