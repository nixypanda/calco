module Page.Users.LoginTest exposing (tests)

import Api.Client as Client
import Component.Users.CredentialForm as CredentialForm
import Expect
import Page.Users.BootstrapSetup as BootstrapSetup
import Page.Users.Login as AuthLogin
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Auth pages"
        [ test "login payload trims username" <|
            \_ ->
                AuthLogin.loginPayload { username = " alice ", password = "secret" }
                    |> Expect.equal (Ok { username = "alice", password = "secret" })
        , test "login payload preserves password exactly" <|
            \_ ->
                AuthLogin.loginPayload { username = "alice", password = " secret " }
                    |> Expect.equal (Ok { username = "alice", password = " secret " })
        , test "login payload rejects missing username" <|
            \_ ->
                AuthLogin.loginPayload { username = " ", password = "secret" }
                    |> Expect.equal (Err "Username is required")
        , test "login rejects missing password" <|
            \_ ->
                AuthLogin.loginPayload { username = "alice", password = "" }
                    |> Expect.equal (Err "Password is required")
        , test "login submit emits trimmed request" <|
            \_ ->
                CredentialForm.Editing { username = " alice ", password = "secret" }
                    |> AuthLogin.update (AuthLogin.FormMsg CredentialForm.Submitted)
                    |> thirdOfThree
                    |> Expect.equal
                        (AuthLogin.RequestLogin { username = "alice", password = "secret" })
        , test "login submit stores validation message" <|
            \_ ->
                CredentialForm.Editing { username = "", password = "secret" }
                    |> AuthLogin.update (AuthLogin.FormMsg CredentialForm.Submitted)
                    |> firstOfThree
                    |> Expect.equal
                        (CredentialForm.Invalid
                            { username = "", password = "secret" }
                            "Username is required"
                        )
        , test "login field edit clears invalid state" <|
            \_ ->
                CredentialForm.Invalid
                    { username = "", password = "secret" }
                    "Username is required"
                    |> AuthLogin.update (AuthLogin.FormMsg (CredentialForm.UsernameChanged "alice"))
                    |> firstOfThree
                    |> Expect.equal
                        (CredentialForm.Editing { username = "alice", password = "secret" })
        , test "login failed completion stores api error with form" <|
            \_ ->
                CredentialForm.Submitting { username = "alice", password = "wrong" }
                    |> AuthLogin.update
                        (AuthLogin.LoginCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> firstOfThree
                    |> Expect.equal
                        (CredentialForm.Failed
                            { username = "alice", password = "wrong" }
                            "Unauthorized"
                        )
        , test "login completion is ignored when not submitting" <|
            \_ ->
                CredentialForm.Editing { username = "alice", password = "secret" }
                    |> AuthLogin.update (AuthLogin.LoginCompleted (Err Client.NetworkError))
                    |> firstAndThird
                    |> Expect.equal
                        ( CredentialForm.Editing { username = "alice", password = "secret" }
                        , AuthLogin.NoOp
                        )
        , test "setup rejects short password" <|
            \_ ->
                BootstrapSetup.validateBootstrapAdmin { username = "admin", password = "short" }
                    |> Expect.equal (Err "Password must be at least 8 characters")
        , test "setup submit emits trimmed request" <|
            \_ ->
                CredentialForm.Editing { username = " admin ", password = "long-enough" }
                    |> BootstrapSetup.update (BootstrapSetup.FormMsg CredentialForm.Submitted)
                    |> thirdOfThree
                    |> Expect.equal
                        (BootstrapSetup.RequestCreateAdmin
                            { username = "admin", password = "long-enough" }
                        )
        ]


firstOfThree : ( a, b, c ) -> a
firstOfThree ( a, _, _ ) =
    a


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, c ) =
    c


firstAndThird : ( a, b, c ) -> ( a, c )
firstAndThird ( a, _, c ) =
    ( a, c )
