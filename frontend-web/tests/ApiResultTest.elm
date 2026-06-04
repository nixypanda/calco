module ApiResultTest exposing (tests)

import Api.Client as Client
import Api.Result as ApiResult
import Expect
import Test exposing (Test, describe, test)


type OutMsg
    = NoOp
    | SessionExpired


type alias Model =
    { error : Maybe String
    }


tests : Test
tests =
    describe "Api.Result"
        [ test "non-unauthorized failures apply display error and return NoOp" <|
            \_ ->
                ApiResult.failure config Client.NetworkError emptyModel
                    |> resultSummary
                    |> Expect.equal ( Just "Network error", NoOp )
        , test "unauthorized failures apply display error and return SessionExpired" <|
            \_ ->
                ApiResult.failure config (Client.BadStatus 401 "unauthorized" "Sign in again") emptyModel
                    |> resultSummary
                    |> Expect.equal ( Just "unauthorized: Sign in again", SessionExpired )
        ]


config :
    { noOp : OutMsg
    , sessionExpired : OutMsg
    , applyError : String -> Model -> Model
    }
config =
    { noOp = NoOp
    , sessionExpired = SessionExpired
    , applyError = \message model -> { model | error = Just message }
    }


emptyModel : Model
emptyModel =
    { error = Nothing }


resultSummary : ( Model, Cmd msg, OutMsg ) -> ( Maybe String, OutMsg )
resultSummary ( model, _, outMsg ) =
    ( model.error, outMsg )
