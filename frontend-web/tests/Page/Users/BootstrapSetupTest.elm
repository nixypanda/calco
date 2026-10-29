module Page.Users.BootstrapSetupTest exposing (tests)

import Component.Users.CredentialForm as CredentialForm
import Data.Auth as Auth
import Expect
import Page.Users.BootstrapSetup as BootstrapSetup
import Api.Client as Client
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.BootstrapSetup"
        [ test "a user creates the first admin" <|
            \_ ->
                Story.start ( BootstrapSetup.init, BootstrapSetup.NoOp )
                    |> step (formMsg (CredentialForm.UsernameChanged "admin"))
                    |> step (formMsg (CredentialForm.PasswordChanged "long-enough"))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (BootstrapSetup.CreateAdminCompleted (Ok loginSession))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (BootstrapSetup.CreateAdminSucceeded loginSession)
                        )
        , test "a failed create can be retried" <|
            \_ ->
                Story.start ( BootstrapSetup.init, BootstrapSetup.NoOp )
                    |> step (formMsg (CredentialForm.UsernameChanged "admin"))
                    |> step (formMsg (CredentialForm.PasswordChanged "long-enough"))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (BootstrapSetup.CreateAdminCompleted (Err Client.NetworkError))
                    |> step (formMsg CredentialForm.Submitted)
                    |> step (BootstrapSetup.CreateAdminCompleted (Ok loginSession))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (BootstrapSetup.CreateAdminSucceeded loginSession)
                        )
        ]


stepWithOut :
    BootstrapSetup.Msg
    -> BootstrapSetup.Model
    -> ( BootstrapSetup.Model, BootstrapSetup.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            BootstrapSetup.update msg model
    in
    ( next, outMsg )


-- STORY PIPELINE


type alias Journey =
    Story.Journey BootstrapSetup.Model BootstrapSetup.OutMsg


step : BootstrapSetup.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( BootstrapSetup.Model, BootstrapSetup.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


formMsg : CredentialForm.Msg -> BootstrapSetup.Msg
formMsg =
    BootstrapSetup.FormMsg


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }
