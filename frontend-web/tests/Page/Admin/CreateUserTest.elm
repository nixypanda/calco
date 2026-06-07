module Page.Admin.CreateUserTest exposing (tests)

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
                    |> .state
                    |> Expect.equal
                        (CreateUser.Editing emptyForm)
        , test "init emits NoOp" <|
            \_ ->
                CreateUser.init
                    |> Tuple.second
                    |> Expect.equal CreateUser.NoOp
        , test "Submitted trims username and display name and emits RequestCreateUser" <|
            \_ ->
                { initialModel
                    | state =
                        CreateUser.Editing
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
                    | state =
                        CreateUser.Editing
                            { username = ""
                            , displayName = "Alice"
                            , initialPassword = "secret"
                            }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .state
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
                { initialModel
                    | state =
                        CreateUser.Editing
                            { username = "alice"
                            , displayName = ""
                            , initialPassword = "secret"
                            }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .state
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
                { initialModel
                    | state =
                        CreateUser.Editing
                            { username = "alice"
                            , displayName = "Alice"
                            , initialPassword = ""
                            }
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .state
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
                { initialModel
                    | state =
                        CreateUser.Invalid
                            { username = "alice"
                            , displayName = "Alice"
                            , initialPassword = "secret"
                            }
                            CreateUser.UsernameRequired
                }
                    |> CreateUser.update CreateUser.Submitted
                    |> firstOfThree
                    |> .state
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
                    |> .state
                    |> Expect.equal (CreateUser.Failed emptyForm "bad: Bad request")
        , test "field changes update form correctly" <|
            \_ ->
                initialModel
                    |> CreateUser.update (CreateUser.UsernameChanged "bob")
                    |> firstOfThree
                    |> .state
                    |> Expect.equal (CreateUser.Editing { emptyForm | username = "bob" })
        ]


initialModel : CreateUser.Model
initialModel =
    CreateUser.init |> Tuple.first


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
