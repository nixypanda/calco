module Page.Users.EditUserTest exposing (tests)

import Api.Client as Client
import Data.User exposing (User)
import Expect
import I18n
import Page.Users.EditUser as EditUser
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Unauthorized"


serverError : Client.ApiError
serverError =
    Client.BadStatus 500 "boom" "Failed"


tests : Test
tests =
    describe "Page.Users.EditUser"
        [ test "loading a user requests the user and renders the account card" <|
            \_ ->
                let
                    ( loading, request ) =
                        EditUser.init "u1"

                    loaded : EditUser.Model
                    loaded =
                        step (EditUser.UserLoaded (Ok alice)) loading
                in
                { request = request
                , loading = toScreen loading |> .phase
                , loaded = toScreen loaded
                }
                    |> Expect.equal
                        { request = EditUser.RequestUser "u1"
                        , loading = "loading"
                        , loaded =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "idle"
                            , error = Nothing
                            , password = ""
                            , disableModal = False
                            }
                        }
        , test "a failed user load shows an error and an unauthorized load expires the session" <|
            \_ ->
                let
                    loading : EditUser.Model
                    loading =
                        Tuple.first (EditUser.init "u1")

                    failed : EditUser.Model
                    failed =
                        step (EditUser.UserLoaded (Err serverError)) loading
                in
                { failed = toScreen failed
                , unauthorized = out (EditUser.UserLoaded (Err unauthorized)) loading
                }
                    |> Expect.equal
                        { failed =
                            { phase = "failed"
                            , title = Nothing
                            , status = Nothing
                            , action = "none"
                            , error = Just "Failed"
                            , password = ""
                            , disableModal = False
                            }
                        , unauthorized = EditUser.SessionExpired
                        }
        , test "submitting an empty password is rejected and editing clears the error" <|
            \_ ->
                let
                    invalid : EditUser.Model
                    invalid =
                        step EditUser.ResetSubmitted (loadedUser "")

                    editing : EditUser.Model
                    editing =
                        step (EditUser.PasswordChanged "new") invalid
                in
                { invalid = toScreen invalid
                , cleared = toScreen editing
                }
                    |> Expect.equal
                        { invalid =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "invalid"
                            , error = Just (I18n.en TidUsersNewPasswordRequired)
                            , password = ""
                            , disableModal = False
                            }
                        , cleared =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "idle"
                            , error = Nothing
                            , password = "new"
                            , disableModal = False
                            }
                        }
        , test "a valid reset requests the password once, succeeds, and expires on 401" <|
            \_ ->
                let
                    ready : EditUser.Model
                    ready =
                        loadedUser "new-password"

                    pending : EditUser.Model
                    pending =
                        step EditUser.ResetSubmitted ready
                in
                { request = out EditUser.ResetSubmitted ready
                , pending = toScreen pending
                , doubleSubmit = out EditUser.ResetSubmitted pending
                , completed = out (EditUser.ResetCompleted (Ok ())) pending
                , completedScreen = toScreen (step (EditUser.ResetCompleted (Ok ())) pending)
                , unauthorized = out (EditUser.ResetCompleted (Err unauthorized)) pending
                }
                    |> Expect.equal
                        { request =
                            EditUser.RequestResetPassword "u1" { newPassword = "new-password" }
                        , pending =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "resetting"
                            , error = Nothing
                            , password = "new-password"
                            , disableModal = False
                            }
                        , doubleSubmit = EditUser.NoOp
                        , completed = EditUser.UpdateSucceeded
                        , completedScreen =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "idle"
                            , error = Nothing
                            , password = ""
                            , disableModal = False
                            }
                        , unauthorized = EditUser.SessionExpired
                        }
        , test "disabling confirms, requests the change, and retries after failure" <|
            \_ ->
                let
                    ready : EditUser.Model
                    ready =
                        loadedUser ""

                    confirming : EditUser.Model
                    confirming =
                        step EditUser.DisableClicked ready

                    disabling : EditUser.Model
                    disabling =
                        step EditUser.DisableConfirmClicked confirming

                    failed : EditUser.Model
                    failed =
                        step (EditUser.DisableCompleted (Err Client.NetworkError)) disabling

                    retried : EditUser.Model
                    retried =
                        step EditUser.DisableConfirmClicked (step EditUser.DisableClicked failed)

                    succeeded : EditUser.Model
                    succeeded =
                        step (EditUser.DisableCompleted (Ok ())) retried
                in
                { confirming = toScreen confirming
                , cancel = toScreen (step EditUser.CancelDisableClicked confirming)
                , request = out EditUser.DisableConfirmClicked confirming
                , disabling = toScreen disabling
                , failureOut = out (EditUser.DisableCompleted (Err Client.NetworkError)) disabling
                , failed = toScreen failed
                , completed = out (EditUser.DisableCompleted (Ok ())) retried
                , succeeded = toScreen succeeded
                }
                    |> Expect.equal
                        { confirming =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "confirming"
                            , error = Nothing
                            , password = ""
                            , disableModal = True
                            }
                        , cancel =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "idle"
                            , error = Nothing
                            , password = ""
                            , disableModal = False
                            }
                        , request = EditUser.RequestDisableUser "u1"
                        , disabling =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "disabling"
                            , error = Nothing
                            , password = ""
                            , disableModal = True
                            }
                        , failureOut = EditUser.NoOp
                        , failed =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "failed"
                            , error = Just networkErrorMessage
                            , password = ""
                            , disableModal = False
                            }
                        , completed = EditUser.UpdateSucceeded
                        , succeeded =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "active"
                            , action = "idle"
                            , error = Nothing
                            , password = ""
                            , disableModal = False
                            }
                        }
        , test "enabling a disabled user requests the change and succeeds" <|
            \_ ->
                let
                    ready : EditUser.Model
                    ready =
                        loadedDisabledUser

                    enabling : EditUser.Model
                    enabling =
                        step EditUser.EnableClicked ready
                in
                { request = out EditUser.EnableClicked ready
                , enabling = toScreen enabling
                , completed = out (EditUser.EnableCompleted (Ok ())) enabling
                }
                    |> Expect.equal
                        { request = EditUser.RequestEnableUser "u1"
                        , enabling =
                            { phase = "loaded"
                            , title = Just "Alice"
                            , status = Just "disabled"
                            , action = "enabling"
                            , error = Nothing
                            , password = ""
                            , disableModal = False
                            }
                        , completed = EditUser.UpdateSucceeded
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , title : Maybe String
    , status : Maybe String
    , action : String
    , error : Maybe String
    , password : String
    , disableModal : Bool
    }


toScreen : EditUser.Model -> Screen
toScreen model =
    case model.status of
        EditUser.Loading ->
            { phase = "loading"
            , title = Nothing
            , status = Nothing
            , action = "none"
            , error = Nothing
            , password = ""
            , disableModal = False
            }

        EditUser.LoadFailed error ->
            { phase = "failed"
            , title = Nothing
            , status = Nothing
            , action = "none"
            , error = Just (Client.displayError error)
            , password = ""
            , disableModal = False
            }

        EditUser.Loaded loaded actionState ->
            { phase = "loaded"
            , title = Just loaded.user.displayName
            , status = Just loaded.user.status
            , action = actionName actionState
            , error = screenError actionState
            , password = loaded.password
            , disableModal =
                actionState == EditUser.DisableConfirming || actionState == EditUser.DisablingUser
            }


actionName : EditUser.ActionState -> String
actionName actionState =
    case actionState of
        EditUser.Idle ->
            "idle"

        EditUser.Invalid _ ->
            "invalid"

        EditUser.ResettingPassword ->
            "resetting"

        EditUser.DisableConfirming ->
            "confirming"

        EditUser.DisablingUser ->
            "disabling"

        EditUser.EnablingUser ->
            "enabling"

        EditUser.ActionFailed _ ->
            "failed"


screenError : EditUser.ActionState -> Maybe String
screenError actionState =
    case actionState of
        EditUser.Invalid problem ->
            Just (problemMessage problem)

        EditUser.ActionFailed message ->
            Just message

        _ ->
            Nothing


problemMessage : EditUser.Problem -> String
problemMessage problem =
    case problem of
        EditUser.NewPasswordRequired ->
            I18n.en TidUsersNewPasswordRequired



-- HELPERS


step : EditUser.Msg -> EditUser.Model -> EditUser.Model
step msg model =
    first (EditUser.update msg model)


out : EditUser.Msg -> EditUser.Model -> EditUser.OutMsg
out msg model =
    third (EditUser.update msg model)


loadedUser : String -> EditUser.Model
loadedUser password =
    Tuple.first (EditUser.init "u1")
        |> step (EditUser.UserLoaded (Ok alice))
        |> step (EditUser.PasswordChanged password)


loadedDisabledUser : EditUser.Model
loadedDisabledUser =
    Tuple.first (EditUser.init "u1")
        |> step (EditUser.UserLoaded (Ok disabledAlice))


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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
