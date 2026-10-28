module Page.Users.EditUserTest exposing (tests)

import Api.Client as Client
import Data.User exposing (User)
import Expect
import I18n
import Page.Users.EditUser as EditUser
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Users.EditUser"
        [ test "an empty reset password is rejected, then a failed reset retries" <|
            \_ ->
                let
                    loaded : EditUser.Model
                    loaded =
                        loadedFromUser alice

                    emptyPassword : EditUser.Model
                    emptyPassword =
                        step EditUser.ResetSubmitted loaded

                    edited : EditUser.Model
                    edited =
                        step (EditUser.PasswordChanged "new-password") emptyPassword

                    pending : EditUser.Model
                    pending =
                        step EditUser.ResetSubmitted edited

                    failed : EditUser.Model
                    failed =
                        step (EditUser.ResetCompleted (Err Client.NetworkError)) pending

                    retrying : EditUser.Model
                    retrying =
                        step EditUser.ResetSubmitted failed

                    succeeded : EditUser.Model
                    succeeded =
                        step (EditUser.ResetCompleted (Ok ())) retrying
                in
                { emptyError = (toScreen emptyPassword).error
                , request = out EditUser.ResetSubmitted edited
                , failedError = (toScreen failed).error
                , retryRequest = out EditUser.ResetSubmitted failed
                , finalOut = out (EditUser.ResetCompleted (Ok ())) retrying
                , final = toScreen succeeded
                , lateOut = out (EditUser.ResetCompleted (Ok ())) succeeded
                }
                    |> Expect.equal
                        { emptyError = Just (I18n.en TidUsersNewPasswordRequired)
                        , request =
                            EditUser.RequestResetPassword
                                "u1"
                                { newPassword = "new-password" }
                        , failedError = Just Fixtures.networkErrorMessage
                        , retryRequest =
                            EditUser.RequestResetPassword
                                "u1"
                                { newPassword = "new-password" }
                        , finalOut = EditUser.UpdateSucceeded
                        , final = loadedScreen alice
                        , lateOut = EditUser.NoOp
                        }
        , test "disable cancels, fails, retries, and ignores a late completion" <|
            \_ ->
                let
                    loaded : EditUser.Model
                    loaded =
                        loadedFromUser alice

                    confirming : EditUser.Model
                    confirming =
                        step EditUser.DisableClicked loaded

                    cancelled : EditUser.Model
                    cancelled =
                        step EditUser.CancelDisableClicked confirming

                    reopened : EditUser.Model
                    reopened =
                        step EditUser.DisableClicked cancelled

                    disabling : EditUser.Model
                    disabling =
                        step EditUser.DisableConfirmClicked reopened

                    failed : EditUser.Model
                    failed =
                        step
                            (EditUser.DisableCompleted (Err Client.NetworkError))
                            disabling

                    retryConfirm : EditUser.Model
                    retryConfirm =
                        step EditUser.DisableClicked failed

                    retrying : EditUser.Model
                    retrying =
                        step EditUser.DisableConfirmClicked retryConfirm

                    succeeded : EditUser.Model
                    succeeded =
                        step (EditUser.DisableCompleted (Ok ())) retrying
                in
                { confirming = toScreen confirming
                , cancelled = toScreen cancelled
                , request = out EditUser.DisableConfirmClicked reopened
                , failed = toScreen failed
                , retryRequest = out EditUser.DisableConfirmClicked retryConfirm
                , finalOut = out (EditUser.DisableCompleted (Ok ())) retrying
                , final = toScreen succeeded
                , lateOut = out (EditUser.DisableCompleted (Ok ())) succeeded
                }
                    |> Expect.equal
                        { confirming =
                            withModal
                                (disableModal (I18n.en TidUsersDisableUser))
                                (loadedScreen alice)
                        , cancelled = loadedScreen alice
                        , request = EditUser.RequestDisableUser "u1"
                        , failed =
                            withError Fixtures.networkErrorMessage (loadedScreen alice)
                        , retryRequest = EditUser.RequestDisableUser "u1"
                        , finalOut = EditUser.UpdateSucceeded
                        , final = loadedScreen alice
                        , lateOut = EditUser.NoOp
                        }
        , test "enabling a disabled user requests the change and a 401 expires" <|
            \_ ->
                let
                    loaded : EditUser.Model
                    loaded =
                        loadedFromUser disabledAlice

                    enabling : EditUser.Model
                    enabling =
                        step EditUser.EnableClicked loaded

                    afterUnauthorized : EditUser.Model
                    afterUnauthorized =
                        step
                            (EditUser.EnableCompleted (Err Fixtures.unauthorized))
                            enabling
                in
                { request = out EditUser.EnableClicked loaded
                , enabling = toScreen enabling
                , finalOut =
                    out
                        (EditUser.EnableCompleted (Err Fixtures.unauthorized))
                        enabling
                , final = toScreen afterUnauthorized
                , lateOut = out (EditUser.EnableCompleted (Ok ())) afterUnauthorized
                }
                    |> Expect.equal
                        { request = EditUser.RequestEnableUser "u1"
                        , enabling =
                            withActionLabel
                                (I18n.en TidUsersEnabling)
                                (loadedScreen disabledAlice)
                        , finalOut = EditUser.SessionExpired
                        , final =
                            withError "Sign in again" (loadedScreen disabledAlice)
                        , lateOut = EditUser.NoOp
                        }
        ]



-- SCREEN PROJECTION


type alias Modal =
    { title : String, actionLabel : String }


type alias Screen =
    { error : Maybe String
    , resetLabel : Maybe String
    , actionLabel : Maybe String
    , modal : Maybe Modal
    , password : String
    }


toScreen : EditUser.Model -> Screen
toScreen model =
    case model.status of
        EditUser.Loading ->
            emptyScreen

        EditUser.LoadFailed _ ->
            emptyScreen

        EditUser.Loaded loadedUser actionState ->
            { error = screenError actionState
            , resetLabel =
                Just
                    (if actionState == EditUser.ResettingPassword then
                        I18n.en TidUsersResetting

                     else
                        I18n.en TidUsersResetPassword
                    )
            , actionLabel = Just (actionLabel loadedUser.user actionState)
            , modal = modalView actionState
            , password = loadedUser.password
            }


emptyScreen : Screen
emptyScreen =
    { error = Nothing, resetLabel = Nothing, actionLabel = Nothing, modal = Nothing, password = "" }


loadedScreen : User -> Screen
loadedScreen user =
    { error = Nothing
    , resetLabel = Just (I18n.en TidUsersResetPassword)
    , actionLabel = Just (actionLabel user EditUser.Idle)
    , modal = Nothing
    , password = ""
    }


withModal : Modal -> Screen -> Screen
withModal modal screen =
    { screen | modal = Just modal }


withError : String -> Screen -> Screen
withError message screen =
    { screen | error = Just message }


withActionLabel : String -> Screen -> Screen
withActionLabel label screen =
    { screen | actionLabel = Just label }


actionLabel : User -> EditUser.ActionState -> String
actionLabel user actionState =
    if user.status == "active" then
        if actionState == EditUser.DisablingUser then
            I18n.en TidUsersDisabling

        else
            I18n.en TidUsersDisableUser

    else if actionState == EditUser.EnablingUser then
        I18n.en TidUsersEnabling

    else
        I18n.en TidUsersEnableUser


modalView : EditUser.ActionState -> Maybe Modal
modalView actionState =
    case actionState of
        EditUser.DisableConfirming ->
            Just (disableModal (I18n.en TidUsersDisableUser))

        EditUser.DisablingUser ->
            Just (disableModal (I18n.en TidUsersDisabling))

        _ ->
            Nothing


disableModal : String -> Modal
disableModal label =
    { title = I18n.en TidUsersDisableConfirmTitle
    , actionLabel = label
    }


screenError : EditUser.ActionState -> Maybe String
screenError actionState =
    case actionState of
        EditUser.Invalid _ ->
            Just (I18n.en TidUsersNewPasswordRequired)

        EditUser.ActionFailed message ->
            Just message

        _ ->
            Nothing



-- HELPERS


step : EditUser.Msg -> EditUser.Model -> EditUser.Model
step msg model =
    Fixtures.tupleFirst (EditUser.update msg model)


out : EditUser.Msg -> EditUser.Model -> EditUser.OutMsg
out msg model =
    Fixtures.tupleThird (EditUser.update msg model)


loadedFromUser : User -> EditUser.Model
loadedFromUser user =
    Tuple.first (EditUser.init "u1")
        |> Story.runSteps step [ EditUser.UserLoaded (Ok user) ]


alice : User
alice =
    { id = "u1"
    , username = "alice"
    , displayName = "Alice"
    , status = "active"
    , createdAt = "2026-06-04"
    }


disabledAlice : User
disabledAlice =
    { alice | status = "disabled" }
