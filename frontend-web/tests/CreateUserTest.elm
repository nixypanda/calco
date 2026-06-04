module CreateUserTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import Page.Admin.CreateUser as CreateUser
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Admin.CreateUser"
        [ test "init creates empty form with no error" <|
            \_ ->
                CreateUser.init
                    |> Tuple.first
                    |> .form
                    |> Expect.equal
                        { username = ""
                        , displayName = ""
                        , initialPassword = ""
                        }
        , test "init emits NoOp" <|
            \_ ->
                CreateUser.init
                    |> Tuple.second
                    |> Expect.equal CreateUser.NoOp
        , test "Submitted trims username and display name and emits RequestCreateUser" <|
            \_ ->
                { initialModel
                    | form =
                        { username = " alice "
                        , displayName = " Alice "
                        , initialPassword = "secret"
                        }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> thirdOfThree
                    |> Expect.equal
                        (CreateUser.RequestCreateUser
                            { username = "alice"
                            , displayName = "Alice"
                            , initialPassword = "secret"
                            }
                        )
        , test "Submitted rejects empty username" <|
            \_ ->
                { initialModel
                    | form =
                        { username = ""
                        , displayName = "Alice"
                        , initialPassword = "secret"
                        }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "Username is required")
        , test "Submitted rejects empty display name" <|
            \_ ->
                { initialModel
                    | form =
                        { username = "alice"
                        , displayName = ""
                        , initialPassword = "secret"
                        }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "Display name is required")
        , test "Submitted rejects empty password" <|
            \_ ->
                { initialModel
                    | form =
                        { username = "alice"
                        , displayName = "Alice"
                        , initialPassword = ""
                        }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "Initial password is required")
        , test "Submitted clears previous error on valid data" <|
            \_ ->
                { initialModel
                    | actionError = Just "old error"
                    , form =
                        { username = "alice"
                        , displayName = "Alice"
                        , initialPassword = "secret"
                        }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal Nothing
        , test "Completed success emits CreateSucceeded" <|
            \_ ->
                initialModel
                    |> CreateUser.update (CreateUser.Completed (Ok loginSession))
                    |> thirdOfThree
                    |> Expect.equal CreateUser.CreateSucceeded
        , test "Completed unauthorized emits SessionExpired" <|
            \_ ->
                initialModel
                    |> CreateUser.update
                        (CreateUser.Completed
                            (Err (Client.BadStatus 401 "unauthorized" "Unauthorized"))
                        )
                    |> thirdOfThree
                    |> Expect.equal CreateUser.SessionExpired
        , test "Completed failure stores error" <|
            \_ ->
                initialModel
                    |> CreateUser.update
                        (CreateUser.Completed
                            (Err (Client.BadStatus 400 "bad" "Bad request"))
                        )
                    |> firstOfThree
                    |> .actionError
                    |> Expect.equal (Just "bad: Bad request")
        , test "field changes update form correctly" <|
            \_ ->
                initialModel
                    |> CreateUser.update (CreateUser.UsernameChanged "bob")
                    |> firstOfThree
                    |> .form
                    |> .username
                    |> Expect.equal "bob"
        ]


initialModel : CreateUser.Model
initialModel =
    CreateUser.init |> Tuple.first


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }


firstOfThree : ( a, b, c ) -> a
firstOfThree ( first, _, _ ) =
    first


thirdOfThree : ( a, b, c ) -> c
thirdOfThree ( _, _, third ) =
    third
