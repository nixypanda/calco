module SessionTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import Session
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Session"
        [ test "init starts loading" <|
            \_ ->
                Session.init
                    |> Expect.equal Session.Loading
        , test "auth success stores identity and profile" <|
            \_ ->
                case Session.applyAuthResult (Ok loginSession) Session.init of
                    Session.Authenticated identity ->
                        Expect.equal loginSession.identity identity

                    _ ->
                        Expect.fail "expected Authenticated"
        , test "auth failure clears identity" <|
            \_ ->
                Session.init
                    |> Session.applyAuthResult (Ok loginSession)
                    |> Session.applyAuthResult (Err Client.NetworkError)
                    |> Expect.equal Session.Unauthenticated
        ]


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "1", username = "admin", role = Auth.Admin }
    , profile = Just { id = "p1", displayName = "Admin" }
    }
