module Page.Users.LoginTest exposing (tests)

import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.Login as AuthLogin
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Users.Login"
        [ test "blank submit, a password error, a 401, and a retried login" <|
            \_ ->
                let
                    blank : AuthLogin.Model
                    blank =
                        step (formMsg CredentialForm.Submitted) AuthLogin.init

                    named : AuthLogin.Model
                    named =
                        step (formMsg (CredentialForm.UsernameChanged " alice ")) blank

                    noPassword : AuthLogin.Model
                    noPassword =
                        step (formMsg CredentialForm.Submitted) named

                    filled : AuthLogin.Model
                    filled =
                        step (formMsg (CredentialForm.PasswordChanged "wrong")) noPassword

                    submitted : AuthLogin.Model
                    submitted =
                        step (formMsg CredentialForm.Submitted) filled

                    failed : AuthLogin.Model
                    failed =
                        step
                            (AuthLogin.LoginCompleted (Err Fixtures.unauthorized))
                            submitted

                    edited : AuthLogin.Model
                    edited =
                        step (formMsg (CredentialForm.PasswordChanged "secret")) failed

                    retried : AuthLogin.Model
                    retried =
                        step (formMsg CredentialForm.Submitted) edited

                    succeeded : AuthLogin.Model
                    succeeded =
                        step (AuthLogin.LoginCompleted (Ok loginSession)) retried
                in
                { blankError = (toScreen blank).error
                , noPasswordError = (toScreen noPassword).error
                , request = out (formMsg CredentialForm.Submitted) filled
                , failedError = (toScreen failed).error
                , retryRequest = out (formMsg CredentialForm.Submitted) edited
                , finalOut =
                    out (AuthLogin.LoginCompleted (Ok loginSession)) retried
                , final = toScreen succeeded
                }
                    |> Expect.equal
                        { blankError = Just (I18n.en TidCommonUsernameRequired)
                        , noPasswordError = Just (I18n.en TidLoginPasswordRequired)
                        , request =
                            AuthLogin.RequestLogin
                                { username = "alice", password = "wrong" }
                        , failedError = Just unauthorizedMessage
                        , retryRequest =
                            AuthLogin.RequestLogin
                                { username = "alice", password = "secret" }
                        , finalOut = AuthLogin.LoginSucceeded loginSession
                        , final = { error = Nothing }
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { error : Maybe String }


toScreen : AuthLogin.Model -> Screen
toScreen model =
    { error =
        case model of
            CredentialForm.Invalid _ message ->
                Just message

            CredentialForm.Failed _ message ->
                Just message

            CredentialForm.Editing _ ->
                Nothing

            CredentialForm.Submitting _ ->
                Nothing
    }



-- HELPERS


step : AuthLogin.Msg -> AuthLogin.Model -> AuthLogin.Model
step msg model =
    Fixtures.tupleFirst (AuthLogin.update msg model)


out : AuthLogin.Msg -> AuthLogin.Model -> AuthLogin.OutMsg
out msg model =
    Fixtures.tupleThird (AuthLogin.update msg model)


formMsg : CredentialForm.Msg -> AuthLogin.Msg
formMsg =
    AuthLogin.FormMsg


unauthorizedMessage : String
unauthorizedMessage =
    "Sign in again"


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "alice", username = "alice", role = Auth.User }
    , profile = Nothing
    }
