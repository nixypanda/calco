module AuthPageTest exposing (tests)

import Api.Client as Client
import Expect
import Page.Admin.BootstrapSetup as Setup
import Page.Auth.Login as Login
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Auth pages"
        [ test "login payload trims username" <|
            \_ ->
                Login.loginPayload { username = " alice ", password = "secret" }
                    |> Expect.equal (Ok { username = "alice", password = "secret" })
        , test "login payload preserves password exactly" <|
            \_ ->
                Login.loginPayload { username = "alice", password = " secret " }
                    |> Expect.equal (Ok { username = "alice", password = " secret " })
        , test "login payload rejects missing username" <|
            \_ ->
                Login.loginPayload { username = " ", password = "secret" }
                    |> Expect.equal (Err Login.UsernameRequired)
        , test "login rejects missing password" <|
            \_ ->
                Login.loginPayload { username = "alice", password = "" }
                    |> Expect.equal (Err Login.PasswordRequired)
        , test "login submit moves valid form into submitting state" <|
            \_ ->
                { state = Login.Editing { username = " alice ", password = "secret" } }
                    |> Login.update Login.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (Login.Submitting { username = " alice ", password = "secret" })
        , test "login submit emits trimmed request" <|
            \_ ->
                { state = Login.Editing { username = " alice ", password = "secret" } }
                    |> Login.update Login.Submitted
                    |> thirdOfThree
                    |> Expect.equal (Login.RequestLogin { username = "alice", password = "secret" })
        , test "login submit stores typed validation problem" <|
            \_ ->
                { state = Login.Editing { username = "", password = "secret" } }
                    |> Login.update Login.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (Login.Invalid
                            { username = "", password = "secret" }
                            Login.UsernameRequired
                        )
        , test "login field edit clears invalid state" <|
            \_ ->
                { state =
                    Login.Invalid
                        { username = "", password = "secret" }
                        Login.UsernameRequired
                }
                    |> Login.update (Login.UsernameChanged "alice")
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (Login.Editing { username = "alice", password = "secret" })
        , test "login field edit clears failed state" <|
            \_ ->
                { state =
                    Login.Failed
                        { username = "alice", password = "wrong" }
                        "Invalid credentials"
                }
                    |> Login.update (Login.PasswordChanged "secret")
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (Login.Editing { username = "alice", password = "secret" })
        , test "login failed completion stores api error with form" <|
            \_ ->
                { state = Login.Submitting { username = "alice", password = "wrong" } }
                    |> Login.update
                        (Login.LoginCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (Login.Failed
                            { username = "alice", password = "wrong" }
                            "unauthorized: Unauthorized"
                        )
        , test "login completion is ignored when not submitting" <|
            \_ ->
                { state = Login.Editing { username = "alice", password = "secret" } }
                    |> Login.update (Login.LoginCompleted (Err Client.NetworkError))
                    |> resultSummary
                    |> Expect.equal
                        ( Login.Editing { username = "alice", password = "secret" }
                        , Login.NoOp
                        )
        , test "setup rejects short password" <|
            \_ ->
                Setup.validateBootstrapAdmin { username = "admin", password = "short" }
                    |> Expect.equal (Err Setup.PasswordTooShort)
        , test "setup trims username" <|
            \_ ->
                Setup.validateBootstrapAdmin { username = " admin ", password = "long-enough" }
                    |> Expect.equal (Ok { username = "admin", password = "long-enough" })
        , test "setup rejects missing username" <|
            \_ ->
                Setup.validateBootstrapAdmin { username = " ", password = "long-enough" }
                    |> Expect.equal (Err Setup.UsernameRequired)
        , test "setup submit moves valid form into submitting state" <|
            \_ ->
                { state = Setup.Editing { username = " admin ", password = "long-enough" } }
                    |> Setup.update Setup.Submitted
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (Setup.Submitting
                            { username = " admin ", password = "long-enough" }
                        )
        , test "setup submit emits trimmed request" <|
            \_ ->
                { state = Setup.Editing { username = " admin ", password = "long-enough" } }
                    |> Setup.update Setup.Submitted
                    |> thirdOfThree
                    |> Expect.equal
                        (Setup.RequestCreateAdmin
                            { username = "admin", password = "long-enough" }
                        )
        , test "setup field edit clears failed state" <|
            \_ ->
                { state = Setup.Failed { username = "admin", password = "too-short" } "Bad setup" }
                    |> Setup.update (Setup.PasswordChanged "long-enough")
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (Setup.Editing { username = "admin", password = "long-enough" })
        , test "setup failed completion stores api error with form" <|
            \_ ->
                { state = Setup.Submitting { username = "admin", password = "long-enough" } }
                    |> Setup.update (Setup.CreateAdminCompleted (Err Client.NetworkError))
                    |> firstOfThree
                    |> .state
                    |> Expect.equal
                        (Setup.Failed
                            { username = "admin", password = "long-enough" }
                            "Network error"
                        )
        , test "setup completion is ignored when not submitting" <|
            \_ ->
                { state = Setup.Editing { username = "admin", password = "long-enough" } }
                    |> Setup.update (Setup.CreateAdminCompleted (Err Client.NetworkError))
                    |> setupResultSummary
                    |> Expect.equal
                        ( Setup.Editing { username = "admin", password = "long-enough" }
                        , Setup.NoOp
                        )
        ]


firstOfThree : ( a, b, c ) -> a
firstOfThree ( a, _, _ ) =
    a


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, c ) =
    c


resultSummary : ( Login.Model, Cmd Login.Msg, Login.OutMsg ) -> ( Login.State, Login.OutMsg )
resultSummary ( model, _, outMsg ) =
    ( model.state, outMsg )


setupResultSummary : ( Setup.Model, Cmd Setup.Msg, Setup.OutMsg ) -> ( Setup.State, Setup.OutMsg )
setupResultSummary ( model, _, outMsg ) =
    ( model.state, outMsg )
