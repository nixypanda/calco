module Page.Users.LoginTest exposing (tests)

import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import Page.Users.Login as AuthLogin
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.Login"
        [ test "a user logs in" <|
            \_ ->
                Story.start ( AuthLogin.init, AuthLogin.NoOp )
                    |> step (formMsg (CredentialForm.UsernameChanged "alice"))
                    |> step (formMsg (CredentialForm.PasswordChanged "secret"))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (AuthLogin.LoginCompleted (Ok loginSession))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (AuthLogin.LoginSucceeded loginSession)
                        )
        , test "a failed login can be retried" <|
            \_ ->
                Story.start ( AuthLogin.init, AuthLogin.NoOp )
                    |> step (formMsg (CredentialForm.UsernameChanged "alice"))
                    |> step (formMsg (CredentialForm.PasswordChanged "wrong"))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (AuthLogin.LoginCompleted (Err Fixtures.unauthorized))
                    |> step (formMsg (CredentialForm.PasswordChanged "secret"))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (AuthLogin.LoginCompleted (Ok loginSession))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (AuthLogin.LoginSucceeded loginSession)
                        )
        ]


stepWithOut :
    AuthLogin.Msg
    -> AuthLogin.Model
    -> ( AuthLogin.Model, AuthLogin.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            AuthLogin.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey AuthLogin.Model AuthLogin.OutMsg


step : AuthLogin.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( AuthLogin.Model, AuthLogin.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


formMsg : CredentialForm.Msg -> AuthLogin.Msg
formMsg =
    AuthLogin.FormMsg


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "alice", username = "alice", role = Auth.User }
    , profile = Nothing
    }
