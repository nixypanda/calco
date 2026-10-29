module Page.Users.CreateUserTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import Page.Users.CreateUser as CreateUser
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.CreateUser"
        [ test "a user creates an account" <|
            \_ ->
                Story.start ( CreateUser.init, CreateUser.NoOp )
                    |> step (CreateUser.UsernameChanged "alice")
                    |> step (CreateUser.DisplayNameChanged "Alice")
                    |> step (CreateUser.PasswordChanged "secret")
                    |> step CreateUser.Submitted
                    |> step (CreateUser.Completed (Ok loginSession))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal CreateUser.CreateSucceeded
                        )
        , test "a failed create can be retried and a 401 expires" <|
            \_ ->
                Story.start ( CreateUser.init, CreateUser.NoOp )
                    |> step (CreateUser.UsernameChanged "alice")
                    |> step (CreateUser.DisplayNameChanged "Alice")
                    |> step (CreateUser.PasswordChanged "secret")
                    |> step CreateUser.Submitted
                    |> step (CreateUser.Completed (Err Client.NetworkError))
                    |> step CreateUser.Submitted
                    |> step (CreateUser.Completed (Err Fixtures.unauthorized))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal CreateUser.SessionExpired
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey CreateUser.Model CreateUser.OutMsg


step : CreateUser.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CreateUser.update)


finish :
    (( CreateUser.Model, CreateUser.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "alice", username = "alice", role = Auth.User }
    , profile = Nothing
    }
