module AdminDashboardTest exposing (tests)

import Data.Route exposing (Route(..))
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
