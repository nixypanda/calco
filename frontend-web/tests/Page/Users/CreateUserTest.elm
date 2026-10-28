module Page.Users.CreateUserTest exposing (tests)

import Api.Client as Client
import Data.Auth as Auth
import Expect
import I18n
import Page.Users.CreateUser as CreateUser
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Users.CreateUser"
        [ test "each required field is reported, then a failed create retries" <|
            \_ ->
                let
                    blank : CreateUser.Model
                    blank =
                        step CreateUser.Submitted CreateUser.init

                    named : CreateUser.Model
                    named =
                        step (CreateUser.UsernameChanged " alice ") blank

                    noDisplayName : CreateUser.Model
                    noDisplayName =
                        step CreateUser.Submitted named

                    displayed : CreateUser.Model
                    displayed =
                        step (CreateUser.DisplayNameChanged " Alice ") noDisplayName

                    noPassword : CreateUser.Model
                    noPassword =
                        step CreateUser.Submitted displayed

                    filled : CreateUser.Model
                    filled =
                        step (CreateUser.PasswordChanged "secret") noPassword

                    submitted : CreateUser.Model
                    submitted =
                        step CreateUser.Submitted filled

                    failed : CreateUser.Model
                    failed =
                        step (CreateUser.Completed (Err Client.NetworkError)) submitted

                    retried : CreateUser.Model
                    retried =
                        step CreateUser.Submitted failed

                    succeeded : CreateUser.Model
                    succeeded =
                        step (CreateUser.Completed (Ok loginSession)) retried
                in
                { blankError = (toScreen blank).error
                , displayNameError = (toScreen noDisplayName).error
                , passwordError = (toScreen noPassword).error
                , request = out CreateUser.Submitted filled
                , failedError = (toScreen failed).error
                , retryRequest = out CreateUser.Submitted failed
                , finalOut =
                    out (CreateUser.Completed (Ok loginSession)) retried
                , final = toScreen succeeded
                }
                    |> Expect.equal
                        { blankError = Just (I18n.en TidCommonUsernameRequired)
                        , displayNameError = Just (I18n.en TidUsersDisplayNameRequired)
                        , passwordError = Just (I18n.en TidUsersInitialPasswordRequired)
                        , request =
                            CreateUser.RequestCreateUser
                                { username = "alice"
                                , displayName = "Alice"
                                , initialPassword = "secret"
                                }
                        , failedError = Just Fixtures.networkErrorMessage
                        , retryRequest =
                            CreateUser.RequestCreateUser
                                { username = "alice"
                                , displayName = "Alice"
                                , initialPassword = "secret"
                                }
                        , finalOut = CreateUser.CreateSucceeded
                        , final = { error = Nothing }
                        }
        , test "blank submit fails validation, then a filled 401 expires the session" <|
            \_ ->
                let
                    ( blank, blankOut ) =
                        stepOnce CreateUser.Submitted CreateUser.init

                    filled : Result String ( CreateUser.Model, List CreateUser.OutMsg )
                    filled =
                        runStepsResult stepWithOut
                            [ CreateUser.UsernameChanged " alice "
                            , CreateUser.DisplayNameChanged " Alice "
                            , CreateUser.PasswordChanged "secret"
                            , CreateUser.Submitted
                            ]
                            blank
                in
                case filled of
                    Ok ( submitted, [ _, _, _, submitOut ] ) ->
                        { blankError = (toScreen blank).error
                        , blankOut = blankOut
                        , submitOut = submitOut
                        , finalOut =
                            out (CreateUser.Completed (Err Fixtures.unauthorized)) submitted
                        }
                            |> Expect.equal
                                { blankError = Just (I18n.en TidCommonUsernameRequired)
                                , blankOut = CreateUser.NoOp
                                , submitOut =
                                    CreateUser.RequestCreateUser
                                        { username = "alice"
                                        , displayName = "Alice"
                                        , initialPassword = "secret"
                                        }
                                , finalOut = CreateUser.SessionExpired
                                }

                    Ok _ ->
                        Expect.fail "the filled submit should be the only request"

                    Err message ->
                        Expect.fail message
        ]



-- SCREEN PROJECTION


type alias Screen =
    { error : Maybe String }


toScreen : CreateUser.Model -> Screen
toScreen model =
    { error =
        case model of
            CreateUser.Invalid _ problem ->
                Just (problemMessage problem)

            CreateUser.Failed _ message ->
                Just message

            CreateUser.Editing _ ->
                Nothing

            CreateUser.Submitting _ ->
                Nothing

            CreateUser.Succeeded ->
                Nothing
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
    Fixtures.tupleFirst (CreateUser.update msg model)


stepOnce : CreateUser.Msg -> CreateUser.Model -> ( CreateUser.Model, CreateUser.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            CreateUser.update msg model
    in
    ( next, outMsg )


stepWithOut : CreateUser.Msg -> CreateUser.Model -> Maybe ( CreateUser.Model, CreateUser.OutMsg )
stepWithOut msg model =
    let
        ( next, outMsg ) =
            stepOnce msg model
    in
    if next == model && outMsg == CreateUser.NoOp then
        Nothing

    else
        Just ( next, outMsg )


out : CreateUser.Msg -> CreateUser.Model -> CreateUser.OutMsg
out msg model =
    Fixtures.tupleThird (CreateUser.update msg model)


loginSession : Auth.LoginSession
loginSession =
    { identity = { id = "alice", username = "alice", role = Auth.User }
    , profile = Nothing
    }
