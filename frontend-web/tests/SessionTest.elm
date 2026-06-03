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
                Session.init.state
                    |> Expect.equal Session.Loading
        , test "auth success stores identity and profile" <|
            \_ ->
                Session.init
                    |> Session.applyAuthResult (Ok loginSession)
                    |> .identity
                    |> Expect.equal (Just loginSession.identity)
        , test "auth failure clears identity" <|
            \_ ->
                let
                    base : Session.Session
                    base =
                        Session.init
                in
                { base | identity = Just loginSession.identity }
                    |> Session.applyAuthResult (Err Client.NetworkError)
                    |> .identity
                    |> Expect.equal Nothing
        ]


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "1", username = "admin", role = Auth.Admin }
    , profile = Just { id = "p1", displayName = "Admin" }
    }
