module EditUserTest exposing (tests)

import Api.Client as Client
import Data.User as User
import Expect
import Lib.Loadable exposing (Loadable(..))
import Page.Admin.EditUser as EditUser
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Admin.EditUser"
        [ test "init starts with user loading and emits RequestUser" <|
            \_ ->
                let
                    ( model, outMsg ) =
                        EditUser.init "u1"
                in
                ( model.user, outMsg )
                    |> Expect.equal ( Loading, EditUser.RequestUser "u1" )
        , test "init stores userId" <|
            \_ ->
                EditUser.init "u1"
                    |> Tuple.first
                    |> .userId
                    |> Expect.equal "u1"
        , test "UserLoaded success stores user" <|
            \_ ->
                initialModel
                    |> EditUser.update (EditUser.UserLoaded (Ok user))
                    |> firstOfThree
                    |> .user
                    |> Expect.equal (Success user)
        , test "UserLoaded unauthorized emits SessionExpired" <|
            \_ ->
                initialModel
                    |> EditUser.update
                        (EditUser.UserLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "UserLoaded failure stores error" <|
            \_ ->
                initialModel
                    |> EditUser.update
                        (EditUser.UserLoaded
                            (Err (Client.BadStatus 500 "boom" "Failed"))
                        )
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "boom: Failed")
        , test "PasswordChanged updates password" <|
            \_ ->
                initialModel
                    |> EditUser.update (EditUser.PasswordChanged "new-password")
                    |> firstOfThree
                    |> .password
                    |> Expect.equal "new-password"
        , test "ResetSubmitted with empty password shows error" <|
            \_ ->
                initialModel
                    |> EditUser.update EditUser.ResetSubmitted
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "New password is required")
        , test "ResetSubmitted with valid password emits RequestResetPassword" <|
            \_ ->
                { initialModel | password = "new-password" }
                    |> EditUser.update EditUser.ResetSubmitted
                    |> thirdOfThree
                    |> Expect.equal
                        (EditUser.RequestResetPassword "u1" { newPassword = "new-password" })
        , test "ResetCompleted success emits UpdateSucceeded" <|
            \_ ->
                initialModel
                    |> EditUser.update (EditUser.ResetCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "ResetCompleted clears password on success" <|
            \_ ->
                { initialModel | password = "old" }
                    |> EditUser.update (EditUser.ResetCompleted (Ok ()))
                    |> firstOfThree
                    |> .password
                    |> Expect.equal ""
        , test "ResetCompleted unauthorized emits SessionExpired" <|
            \_ ->
                initialModel
                    |> EditUser.update
                        (EditUser.ResetCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "DisableClicked emits RequestDisableUser" <|
            \_ ->
                initialModel
                    |> EditUser.update EditUser.DisableClicked
                    |> thirdOfThree
                    |> Expect.equal (EditUser.RequestDisableUser "u1")
        , test "DisableCompleted success emits UpdateSucceeded" <|
            \_ ->
                initialModel
                    |> EditUser.update (EditUser.DisableCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "DisableCompleted unauthorized emits SessionExpired" <|
            \_ ->
                initialModel
                    |> EditUser.update
                        (EditUser.DisableCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "EnableClicked emits RequestEnableUser" <|
            \_ ->
                initialModel
                    |> EditUser.update EditUser.EnableClicked
                    |> thirdOfThree
                    |> Expect.equal (EditUser.RequestEnableUser "u1")
        , test "EnableCompleted success emits UpdateSucceeded" <|
            \_ ->
                initialModel
                    |> EditUser.update (EditUser.EnableCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "EnableCompleted unauthorized emits SessionExpired" <|
            \_ ->
                initialModel
                    |> EditUser.update
                        (EditUser.EnableCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        ]


initialModel : EditUser.Model
initialModel =
    EditUser.init "u1" |> Tuple.first


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
