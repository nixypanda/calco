module Page.Auth.LoginTest exposing (tests)

import Api.Client as Client
import Expect
import Page.Admin.BootstrapSetup as BootstrapSetup
import Page.Auth.Login as AuthLogin
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
                    |> Expect.equal (Err AuthLogin.UsernameRequired)
        , test "login rejects missing password" <|
            \_ ->
                AuthLogin.loginPayload { username = "alice", password = "" }
                    |> Expect.equal (Err AuthLogin.PasswordRequired)
        , test "login submit moves valid form into submitting state" <|
            \_ ->
                { state = AuthLogin.Editing, form = { username = " alice ", password = "secret" } }
                    |> AuthLogin.update AuthLogin.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal AuthLogin.Submitting
        , test "login submit emits trimmed request" <|
            \_ ->
                { state = AuthLogin.Editing, form = { username = " alice ", password = "secret" } }
                    |> AuthLogin.update AuthLogin.Submitted
                    |> thirdOfThree
                    |> Expect.equal
                        (AuthLogin.RequestLogin { username = "alice", password = "secret" })
        , test "login submit stores typed validation problem" <|
            \_ ->
                { state = AuthLogin.Editing, form = { username = "", password = "secret" } }
                    |> AuthLogin.update AuthLogin.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (AuthLogin.Invalid AuthLogin.UsernameRequired)
        , test "login field edit clears invalid state" <|
            \_ ->
                { state = AuthLogin.Invalid AuthLogin.UsernameRequired
                , form = { username = "", password = "secret" }
                }
                    |> AuthLogin.update (AuthLogin.UsernameChanged "alice")
                    |> firstOfThree
                    |> Expect.equal
                        { state = AuthLogin.Editing
                        , form = { username = "alice", password = "secret" }
                        }
        , test "login field edit clears failed state" <|
            \_ ->
                { state = AuthLogin.Failed "Invalid credentials"
                , form = { username = "alice", password = "wrong" }
                }
                    |> AuthLogin.update (AuthLogin.PasswordChanged "secret")
                    |> firstOfThree
                    |> Expect.equal
                        { state = AuthLogin.Editing
                        , form = { username = "alice", password = "secret" }
                        }
        , test "login failed completion stores api error with form" <|
            \_ ->
                { state = AuthLogin.Submitting, form = { username = "alice", password = "wrong" } }
                    |> AuthLogin.update
                        (AuthLogin.LoginCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (AuthLogin.Failed "unauthorized: Unauthorized")
        , test "login completion is ignored when not submitting" <|
            \_ ->
                { state = AuthLogin.Editing, form = { username = "alice", password = "secret" } }
                    |> AuthLogin.update (AuthLogin.LoginCompleted (Err Client.NetworkError))
                    |> resultSummary
                    |> Expect.equal ( AuthLogin.Editing, AuthLogin.NoOp )
        , test "setup rejects short password" <|
            \_ ->
                BootstrapSetup.validateBootstrapAdmin { username = "admin", password = "short" }
                    |> Expect.equal (Err BootstrapSetup.PasswordTooShort)
        , test "setup trims username" <|
            \_ ->
                BootstrapSetup.validateBootstrapAdmin
                    { username = " admin ", password = "long-enough" }
                    |> Expect.equal (Ok { username = "admin", password = "long-enough" })
        , test "setup rejects missing username" <|
            \_ ->
                BootstrapSetup.validateBootstrapAdmin { username = " ", password = "long-enough" }
                    |> Expect.equal (Err BootstrapSetup.UsernameRequired)
        , test "setup submit moves valid form into submitting state" <|
            \_ ->
                { state =
                    BootstrapSetup.Editing { username = " admin ", password = "long-enough" }
                }
                    |> BootstrapSetup.update BootstrapSetup.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (BootstrapSetup.Submitting
                            { username = " admin ", password = "long-enough" }
                        )
        , test "setup submit emits trimmed request" <|
            \_ ->
                { state =
                    BootstrapSetup.Editing { username = " admin ", password = "long-enough" }
                }
                    |> BootstrapSetup.update BootstrapSetup.Submitted
                    |> thirdOfThree
                    |> Expect.equal
                        (BootstrapSetup.RequestCreateAdmin
                            { username = "admin", password = "long-enough" }
                        )
        , test "setup field edit clears failed state" <|
            \_ ->
                { state =
                    BootstrapSetup.Failed
                        { username = "admin", password = "too-short" }
                        "Bad setup"
                }
                    |> BootstrapSetup.update (BootstrapSetup.PasswordChanged "long-enough")
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (BootstrapSetup.Editing
                            { username = "admin", password = "long-enough" }
                        )
        , test "setup failed completion stores api error with form" <|
            \_ ->
                { state =
                    BootstrapSetup.Submitting { username = "admin", password = "long-enough" }
                }
                    |> BootstrapSetup.update
                        (BootstrapSetup.CreateAdminCompleted (Err Client.NetworkError))
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (BootstrapSetup.Failed
                            { username = "admin", password = "long-enough" }
                            "Network error"
                        )
        , test "setup completion is ignored when not submitting" <|
            \_ ->
                { state =
                    BootstrapSetup.Editing { username = "admin", password = "long-enough" }
                }
                    |> BootstrapSetup.update
                        (BootstrapSetup.CreateAdminCompleted (Err Client.NetworkError))
                    |> setupResultSummary
                    |> Expect.equal
                        ( BootstrapSetup.Editing { username = "admin", password = "long-enough" }
                        , BootstrapSetup.NoOp
                        )
        ]


firstOfThree : ( a, b, c ) -> a
firstOfThree ( a, _, _ ) =
    a


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, c ) =
    c


resultSummary :
    ( AuthLogin.Model, Cmd AuthLogin.Msg, AuthLogin.OutMsg )
    -> ( AuthLogin.State, AuthLogin.OutMsg )
resultSummary ( model, _, outMsg ) =
    ( model.state, outMsg )


setupResultSummary :
    ( BootstrapSetup.Model, Cmd BootstrapSetup.Msg, BootstrapSetup.OutMsg )
    -> ( BootstrapSetup.State, BootstrapSetup.OutMsg )
setupResultSummary ( model, _, outMsg ) =
    ( model.state, outMsg )
