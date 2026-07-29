module Page.Users.CreateUserTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import Page.Users.CreateUser as CreateUser
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Users.CreateUser"
        [ test "init creates empty form with no error" <|
            \_ ->
                CreateUser.init
                    |> Expect.equal (CreateUser.Editing emptyForm)
        , test "Submitted trims username and display name and emits RequestCreateUser" <|
            \_ ->
                CreateUser.Editing
                    { username = " alice "
                    , displayName = " Alice "
                    , initialPassword = "secret"
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
                CreateUser.Editing
                    { username = ""
                    , displayName = "Alice"
                    , initialPassword = "secret"
                    }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> Expect.equal
                        (CreateUser.Invalid
                            { username = ""
                            , displayName = "Alice"
                            , initialPassword = "secret"
                            }
                            CreateUser.UsernameRequired
                        )
        , test "Submitted rejects empty display name" <|
            \_ ->
                CreateUser.Editing
                    { username = "alice"
                    , displayName = ""
                    , initialPassword = "secret"
                    }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> Expect.equal
                        (CreateUser.Invalid
                            { username = "alice"
                            , displayName = ""
                            , initialPassword = "secret"
                            }
                            CreateUser.DisplayNameRequired
                        )
        , test "Submitted rejects empty password" <|
            \_ ->
                CreateUser.Editing
                    { username = "alice"
                    , displayName = "Alice"
                    , initialPassword = ""
                    }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> Expect.equal
                        (CreateUser.Invalid
                            { username = "alice"
                            , displayName = "Alice"
                            , initialPassword = ""
                            }
                            CreateUser.InitialPasswordRequired
                        )
        , test "Submitted moves valid data into submitting state" <|
            \_ ->
                CreateUser.Invalid
                    { username = "alice"
                    , displayName = "Alice"
                    , initialPassword = "secret"
                    }
                    CreateUser.UsernameRequired
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> Expect.equal
                        (CreateUser.Submitting
                            { username = "alice"
                            , displayName = "Alice"
                            , initialPassword = "secret"
                            }
                        )
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
                    |> Expect.equal (CreateUser.Failed emptyForm "bad: Bad request")
        ]


initialModel : CreateUser.Model
initialModel =
    CreateUser.init


emptyForm : CreateUser.Form
emptyForm =
    { username = ""
    , displayName = ""
    , initialPassword = ""
    }


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
