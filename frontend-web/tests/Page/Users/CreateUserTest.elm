module Page.Users.CreateUserTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.CreateUser as CreateUser
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Unauthorized"


serverError : Client.ApiError
serverError =
    Client.BadStatus 400 "bad" "Bad request"


tests : Test
tests =
    describe "Page.Users.CreateUser"
        [ test "submitting a new user trims the fields and emits the create request" <|
            \_ ->
                let
                    filled : CreateUser.Model
                    filled =
                        CreateUser.init
                            |> step (CreateUser.UsernameChanged " alice ")
                            |> step (CreateUser.DisplayNameChanged " Alice ")
                            |> step (CreateUser.PasswordChanged "secret")

                    submitting : CreateUser.Model
                    submitting =
                        step CreateUser.Submitted filled
                in
                { request = out CreateUser.Submitted filled
                , screen = toScreen submitting
                }
                    |> Expect.equal
                        { request =
                            CreateUser.RequestCreateUser
                                { username = "alice"
                                , displayName = "Alice"
                                , initialPassword = "secret"
                                }
                        , screen =
                            { phase = "submitting"
                            , username = " alice "
                            , displayName = " Alice "
                            , error = Nothing
                            }
                        }
        , test "submitting incomplete credentials shows the required error and editing clears it" <|
            \_ ->
                let
                    empty : CreateUser.Model
                    empty =
                        CreateUser.init

                    invalid : CreateUser.Model
                    invalid =
                        step CreateUser.Submitted empty
                in
                { invalid = toScreen invalid
                , invalidOut = out CreateUser.Submitted empty
                , cleared = toScreen (step (CreateUser.UsernameChanged "alice") invalid)
                }
                    |> Expect.equal
                        { invalid =
                            { phase = "invalid"
                            , username = ""
                            , displayName = ""
                            , error = Just (I18n.en TidCommonUsernameRequired)
                            }
                        , invalidOut = CreateUser.NoOp
                        , cleared =
                            { phase = "editing"
                            , username = "alice"
                            , displayName = ""
                            , error = Nothing
                            }
                        }
        , test "create completion: success, 401 expiry, and server error" <|
            \_ ->
                let
                    submitting : CreateUser.Model
                    submitting =
                        CreateUser.init
                            |> step (CreateUser.UsernameChanged "alice")
                            |> step (CreateUser.DisplayNameChanged "Alice")
                            |> step (CreateUser.PasswordChanged "secret")
                            |> step CreateUser.Submitted
                in
                { success = out (CreateUser.Completed (Ok loginSession)) submitting
                , unauthorized = out (CreateUser.Completed (Err unauthorized)) submitting
                , failed = toScreen (step (CreateUser.Completed (Err serverError)) submitting)
                , failedOut = out (CreateUser.Completed (Err serverError)) submitting
                }
                    |> Expect.equal
                        { success = CreateUser.CreateSucceeded
                        , unauthorized = CreateUser.SessionExpired
                        , failed =
                            { phase = "failed"
                            , username = "alice"
                            , displayName = "Alice"
                            , error = Just "Bad request"
                            }
                        , failedOut = CreateUser.NoOp
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , username : String
    , displayName : String
    , error : Maybe String
    }


toScreen : CreateUser.Model -> Screen
toScreen model =
    case model of
        CreateUser.Editing form ->
            { phase = "editing"
            , username = form.username
            , displayName = form.displayName
            , error = Nothing
            }

        CreateUser.Invalid form problem ->
            { phase = "invalid"
            , username = form.username
            , displayName = form.displayName
            , error = Just (problemMessage problem)
            }

        CreateUser.Submitting form ->
            { phase = "submitting"
            , username = form.username
            , displayName = form.displayName
            , error = Nothing
            }

        CreateUser.Failed form message ->
            { phase = "failed"
            , username = form.username
            , displayName = form.displayName
            , error = Just message
            }

        CreateUser.Succeeded ->
            { phase = "succeeded"
            , username = ""
            , displayName = ""
            , error = Nothing
            }


problemMessage : CreateUser.Problem -> String
problemMessage problem =
    case problem of
        CreateUser.UsernameRequired ->
            I18n.en TidCommonUsernameRequired

        CreateUser.DisplayNameRequired ->
            I18n.en TidUsersDisplayNameRequired

        CreateUser.InitialPasswordRequired ->
            I18n.en TidUsersInitialPasswordRequired



-- HELPERS


step : CreateUser.Msg -> CreateUser.Model -> CreateUser.Model
step msg model =
    first (CreateUser.update msg model)


out : CreateUser.Msg -> CreateUser.Model -> CreateUser.OutMsg
out msg model =
    third (CreateUser.update msg model)


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "admin", username = "admin", role = Auth.Admin }
    , profile = Nothing
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
