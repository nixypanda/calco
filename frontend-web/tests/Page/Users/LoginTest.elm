module Page.Users.LoginTest exposing (tests)

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.Login as AuthLogin
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Unauthorized"


tests : Test
tests =
    describe "Page.Users.Login"
        [ test "login payload trims username, keeps password, and requires both fields" <|
            \_ ->
                { trimmed =
                    AuthLogin.loginPayload { username = " alice ", password = "secret" }
                , passwordPreserved =
                    AuthLogin.loginPayload { username = "alice", password = " secret " }
                , missingUsername =
                    AuthLogin.loginPayload { username = " ", password = "secret" }
                , missingPassword =
                    AuthLogin.loginPayload { username = "alice", password = "" }
                }
                    |> Expect.equal
                        { trimmed = Ok { username = "alice", password = "secret" }
                        , passwordPreserved = Ok { username = "alice", password = " secret " }
                        , missingUsername = Err (I18n.en TidCommonUsernameRequired)
                        , missingPassword = Err (I18n.en TidLoginPasswordRequired)
                        }
        , test "submitting valid credentials emits a trimmed login request and shows progress" <|
            \_ ->
                let
                    filled : AuthLogin.Model
                    filled =
                        AuthLogin.init
                            |> step (AuthLogin.FormMsg (CredentialForm.UsernameChanged " alice "))
                            |> step (AuthLogin.FormMsg (CredentialForm.PasswordChanged "secret"))

                    submitting : AuthLogin.Model
                    submitting =
                        step (AuthLogin.FormMsg CredentialForm.Submitted) filled
                in
                { request = out (AuthLogin.FormMsg CredentialForm.Submitted) filled
                , screen = toScreen submitting
                }
                    |> Expect.equal
                        { request =
                            AuthLogin.RequestLogin { username = "alice", password = "secret" }
                        , screen = { phase = "submitting", username = " alice ", error = Nothing }
                        }
        , test "submitting without a username shows a validation message and editing clears it" <|
            \_ ->
                let
                    invalid : AuthLogin.Model
                    invalid =
                        step (AuthLogin.FormMsg CredentialForm.Submitted) AuthLogin.init
                in
                { invalid = toScreen invalid
                , invalidOut = out (AuthLogin.FormMsg CredentialForm.Submitted) AuthLogin.init
                , cleared =
                    toScreen
                        (step (AuthLogin.FormMsg (CredentialForm.UsernameChanged "alice")) invalid)
                }
                    |> Expect.equal
                        { invalid =
                            { phase = "invalid"
                            , username = ""
                            , error = Just (I18n.en TidCommonUsernameRequired)
                            }
                        , invalidOut = AuthLogin.NoOp
                        , cleared = { phase = "editing", username = "alice", error = Nothing }
                        }
        , test "a failed login surfaces the server error without expiring the session" <|
            \_ ->
                let
                    submitting : AuthLogin.Model
                    submitting =
                        step
                            (AuthLogin.FormMsg CredentialForm.Submitted)
                            (CredentialForm.Editing { username = "alice", password = "wrong" })
                in
                { success = out (AuthLogin.LoginCompleted (Ok loginSession)) submitting
                , failure = toScreen (step (AuthLogin.LoginCompleted (Err unauthorized)) submitting)
                , failureOut = out (AuthLogin.LoginCompleted (Err unauthorized)) submitting
                }
                    |> Expect.equal
                        { success = AuthLogin.LoginSucceeded loginSession
                        , failure =
                            { phase = "failed", username = "alice", error = Just "Unauthorized" }
                        , failureOut = AuthLogin.NoOp
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , username : String
    , error : Maybe String
    }


toScreen : AuthLogin.Model -> Screen
toScreen model =
    case model of
        CredentialForm.Editing form ->
            { phase = "editing", username = form.username, error = Nothing }

        CredentialForm.Invalid form message ->
            { phase = "invalid", username = form.username, error = Just message }

        CredentialForm.Submitting form ->
            { phase = "submitting", username = form.username, error = Nothing }

        CredentialForm.Failed form message ->
            { phase = "failed", username = form.username, error = Just message }



-- HELPERS


step : AuthLogin.Msg -> AuthLogin.Model -> AuthLogin.Model
step msg model =
    first (AuthLogin.update msg model)


out : AuthLogin.Msg -> AuthLogin.Model -> AuthLogin.OutMsg
out msg model =
    third (AuthLogin.update msg model)


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "alice", username = "alice", role = Auth.User }
    , profile = Nothing
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
