module AuthPageTest exposing (tests)

import Expect
import Page.Admin.BootstrapSetup as Setup
import Page.Auth.Login as Login
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Auth pages"
        [ test "login trims username" <|
            \_ ->
                Login.validateLogin { username = " alice ", password = "secret" }
                    |> Expect.equal (Ok { username = "alice", password = "secret" })
        , test "login rejects missing password" <|
            \_ ->
                Login.validateLogin { username = "alice", password = "" }
                    |> Expect.equal (Err "Username and password are required")
        , test "setup rejects short password" <|
            \_ ->
                Setup.validateBootstrapAdmin { username = "admin", password = "short" }
                    |> Expect.equal (Err "Password must be at least 8 characters")
        , test "setup trims username" <|
            \_ ->
                Setup.validateBootstrapAdmin { username = " admin ", password = "long-enough" }
                    |> Expect.equal (Ok { username = "admin", password = "long-enough" })
        ]
