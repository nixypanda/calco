module SessionTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Session"
        [ test "init starts loading" <|
            \_ ->
                Auth.initSession
                    |> Expect.equal Auth.Loading
        , test "auth success stores identity and profile" <|
            \_ ->
                case Auth.applyAuthResult (Ok loginSession) Auth.initSession of
                    Auth.Authenticated identity ->
                        Expect.equal loginSession.identity identity

                    _ ->
                        Expect.fail "expected Authenticated"
        , test "auth failure clears identity" <|
            \_ ->
                Auth.initSession
                    |> Auth.applyAuthResult (Ok loginSession)
                    |> Auth.applyAuthResult (Err Client.NetworkError)
                    |> Expect.equal Auth.Unauthenticated
        ]


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "1", username = "admin", role = Auth.Admin }
    , profile = Just { id = "p1", displayName = "Admin" }
    }
