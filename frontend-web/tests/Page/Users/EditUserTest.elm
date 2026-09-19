module Page.Users.EditUserTest exposing (tests)

import Api.Client as Client
import Data.User exposing (User)
import Expect
import Page.Users.EditUser as EditUser
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.Users.EditUser"
        [ test "init starts with user loading and emits RequestUser" <|
            \_ ->
                let
                    ( model, outMsg ) =
                        EditUser.init "u1"
                in
                ( model.status, outMsg )
                    |> Expect.equal ( EditUser.Loading, EditUser.RequestUser "u1" )
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
                    |> .status
                    |> Expect.equal (EditUser.Loaded { user = user, password = "" } EditUser.Idle)
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
                    |> .status
                    |> Expect.equal (EditUser.LoadFailed (Client.BadStatus 500 "boom" "Failed"))
        , test "ResetSubmitted with empty password shows error" <|
            \_ ->
                readyModel
                    |> EditUser.update EditUser.ResetSubmitted
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just (EditUser.Invalid EditUser.NewPasswordRequired))
        , test "ResetSubmitted with valid password emits RequestResetPassword" <|
            \_ ->
                readyModelWithPassword "new-password"
                    |> EditUser.update EditUser.ResetSubmitted
                    |> thirdOfThree
                    |> Expect.equal
                        (EditUser.RequestResetPassword "u1" { newPassword = "new-password" })
        , test "ResetSubmitted with valid password marks reset pending" <|
            \_ ->
                readyModelWithPassword "new-password"
                    |> EditUser.update EditUser.ResetSubmitted
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.ResettingPassword)
        , test "ResetCompleted success emits UpdateSucceeded" <|
            \_ ->
                resettingModel
                    |> EditUser.update (EditUser.ResetCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "ResetCompleted clears password on success" <|
            \_ ->
                resettingModel
                    |> EditUser.update (EditUser.ResetCompleted (Ok ()))
                    |> firstOfThree
                    |> passwordFromState
                    |> Expect.equal ""
        , test "ResetCompleted unauthorized emits SessionExpired" <|
            \_ ->
                resettingModel
                    |> EditUser.update
                        (EditUser.ResetCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "DisableClicked emits RequestDisableUser" <|
            \_ ->
                readyModel
                    |> EditUser.update EditUser.DisableClicked
                    |> thirdOfThree
                    |> Expect.equal (EditUser.RequestDisableUser "u1")
        , test "DisableClicked marks disable pending" <|
            \_ ->
                readyModel
                    |> EditUser.update EditUser.DisableClicked
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.DisablingUser)
        , test "DisableCompleted success emits UpdateSucceeded" <|
            \_ ->
                disablingModel
                    |> EditUser.update (EditUser.DisableCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "DisableCompleted unauthorized emits SessionExpired" <|
            \_ ->
                disablingModel
                    |> EditUser.update
                        (EditUser.DisableCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "EnableClicked emits RequestEnableUser" <|
            \_ ->
                disabledReadyModel
                    |> EditUser.update EditUser.EnableClicked
                    |> thirdOfThree
                    |> Expect.equal (EditUser.RequestEnableUser "u1")
        , test "EnableClicked marks enable pending" <|
            \_ ->
                disabledReadyModel
                    |> EditUser.update EditUser.EnableClicked
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.EnablingUser)
        , test "EnableCompleted success emits UpdateSucceeded" <|
            \_ ->
                enablingModel
                    |> EditUser.update (EditUser.EnableCompleted (Ok ()))
                    |> thirdOfThree
                    |> Expect.equal EditUser.UpdateSucceeded
        , test "EnableCompleted unauthorized emits SessionExpired" <|
            \_ ->
                enablingModel
                    |> EditUser.update
                        (EditUser.EnableCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal EditUser.SessionExpired
        , test "PasswordChanged with Invalid state resets to Idle" <|
            \_ ->
                invalidModel
                    |> EditUser.update (EditUser.PasswordChanged "new")
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.Idle)
        , test "PasswordChanged with ActionFailed resets to Idle" <|
            \_ ->
                actionFailedModel
                    |> EditUser.update (EditUser.PasswordChanged "new")
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.Idle)
        , test "PasswordChanged with ResettingPassword keeps ResettingPassword" <|
            \_ ->
                resettingWithNewPasswordModel
                    |> EditUser.update (EditUser.PasswordChanged "new")
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just EditUser.ResettingPassword)
        , test "ResetSubmitted when pending is no-op" <|
            \_ ->
                resettingModel
                    |> EditUser.update EditUser.ResetSubmitted
                    |> firstOfThree
                    |> Expect.equal resettingModel
        , test "DisableClicked when pending is no-op" <|
            \_ ->
                resettingModel
                    |> EditUser.update EditUser.DisableClicked
                    |> firstOfThree
                    |> Expect.equal resettingModel
        , test "EnableClicked when pending is no-op" <|
            \_ ->
                resettingModel
                    |> EditUser.update EditUser.EnableClicked
                    |> firstOfThree
                    |> Expect.equal resettingModel
        , test "ResetCompleted with non-matching action state is no-op" <|
            \_ ->
                disablingModel
                    |> EditUser.update (EditUser.ResetCompleted (Ok ()))
                    |> firstOfThree
                    |> Expect.equal disablingModel
        , test "DisableCompleted failure stores ActionFailed" <|
            \_ ->
                disablingModel
                    |> EditUser.update (EditUser.DisableCompleted (Err Client.NetworkError))
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just (EditUser.ActionFailed networkErrorMessage))
        , test "EnableCompleted failure stores ActionFailed" <|
            \_ ->
                enablingModel
                    |> EditUser.update (EditUser.EnableCompleted (Err Client.NetworkError))
                    |> firstOfThree
                    |> actionStateFromState
                    |> Expect.equal (Just (EditUser.ActionFailed networkErrorMessage))
        ]


initialModel : EditUser.Model
initialModel =
    EditUser.init "u1" |> Tuple.first


readyModel : EditUser.Model
readyModel =
    { initialModel | status = EditUser.Loaded { user = user, password = "" } EditUser.Idle }


disabledReadyModel : EditUser.Model
disabledReadyModel =
    { initialModel | status = EditUser.Loaded { user = disabledUser, password = "" } EditUser.Idle }


readyModelWithPassword : String -> EditUser.Model
readyModelWithPassword password =
    { initialModel | status = EditUser.Loaded { user = user, password = password } EditUser.Idle }


resettingModel : EditUser.Model
resettingModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = user, password = "old" }
                EditUser.ResettingPassword
    }


disablingModel : EditUser.Model
disablingModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = user, password = "" }
                EditUser.DisablingUser
    }


enablingModel : EditUser.Model
enablingModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = disabledUser, password = "" }
                EditUser.EnablingUser
    }


invalidModel : EditUser.Model
invalidModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = user, password = "" }
                (EditUser.Invalid EditUser.NewPasswordRequired)
    }


actionFailedModel : EditUser.Model
actionFailedModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = user, password = "" }
                (EditUser.ActionFailed "old error")
    }


resettingWithNewPasswordModel : EditUser.Model
resettingWithNewPasswordModel =
    { initialModel
        | status =
            EditUser.Loaded
                { user = user, password = "new" }
                EditUser.ResettingPassword
    }


user : User
user =
    { id = "u1"
    , username = "alice"
    , displayName = "Alice"
    , status = "active"
    , createdAt = "2026-06-04"
    }


disabledUser : User
disabledUser =
    { user | status = "disabled" }


firstOfThree : ( a, b, c ) -> a
firstOfThree ( first, _, _ ) =
    first


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, third ) =
    third


passwordFromState : EditUser.Model -> String
passwordFromState model =
    case model.status of
        EditUser.Loaded loadedUser _ ->
            loadedUser.password

        _ ->
            ""


actionStateFromState : EditUser.Model -> Maybe EditUser.ActionState
actionStateFromState model =
    case model.status of
        EditUser.Loaded _ actionState ->
            Just actionState

        _ ->
            Nothing
