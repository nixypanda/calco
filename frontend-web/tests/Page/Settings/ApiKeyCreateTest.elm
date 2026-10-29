module Page.Settings.ApiKeyCreateTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..), CreatableScope(..), CreatedApiKey)
import Expect
import I18n
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeyProjection as Projection
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Settings.ApiKeyCreate"
        [ test "a user creates an API key" <|
            \_ ->
                named
                    |> step ApiKeyCreate.Submitted
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeyCreate.RequestCreate requestId _ ->
                                    Ok (ApiKeyCreate.CreateCompleted requestId (Ok createdBuild))

                                _ ->
                                    Err "expected a create request"
                        )
                    |> finish
                        (\( model, outMsg ) ->
                            { token = createdToken model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { token = Just "token-build"
                                    , finalOut = ApiKeyCreate.NoOp
                                    }
                        )
        , test "a failed create can be retried and expires on 401" <|
            \_ ->
                named
                    |> step ApiKeyCreate.Submitted
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeyCreate.RequestCreate requestId _ ->
                                    Ok
                                        (ApiKeyCreate.CreateCompleted requestId
                                            (Err Client.NetworkError)
                                        )

                                _ ->
                                    Err "expected a create request"
                        )
                    |> step ApiKeyCreate.Submitted
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeyCreate.RequestCreate requestId _ ->
                                    Ok
                                        (ApiKeyCreate.CreateCompleted requestId
                                            (Err Fixtures.unauthorized)
                                        )

                                _ ->
                                    Err "expected a create request"
                        )
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal ApiKeyCreate.SessionExpired
                        )
        , test "a user copies the created key" <|
            \_ ->
                named
                    |> step ApiKeyCreate.Submitted
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeyCreate.RequestCreate requestId _ ->
                                    Ok (ApiKeyCreate.CreateCompleted requestId (Ok createdBuild))

                                _ ->
                                    Err "expected a create request"
                        )
                    |> step ApiKeyCreate.CopyClicked
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeyCreate.CopyText copyId _ ->
                                    Ok (ApiKeyCreate.CopyCompleted copyId True)

                                _ ->
                                    Err "expected a copy request"
                        )
                    |> finish
                        (\( model, outMsg ) ->
                            { feedback = createdFeedback model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { feedback = Just copiedLabel
                                    , finalOut = ApiKeyCreate.NoOp
                                    }
                        )
        ]


stepWithOut :
    ApiKeyCreate.Msg
    -> ApiKeyCreate.Model
    -> ( ApiKeyCreate.Model, ApiKeyCreate.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            ApiKeyCreate.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey ApiKeyCreate.Model ApiKeyCreate.OutMsg


step : ApiKeyCreate.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


bind :
    (ApiKeyCreate.OutMsg -> Result String ApiKeyCreate.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind stepWithOut


finish :
    (( ApiKeyCreate.Model, ApiKeyCreate.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


named : Journey
named =
    Story.start ApiKeyCreate.init
        |> step (ApiKeyCreate.NameChanged "Build script")
        |> step (ApiKeyCreate.ScopeChanged CreatableReadWrite)
        |> step (ApiKeyCreate.ExpiryChanged ApiKeyCreate.NeverExpires)


createdToken : ApiKeyCreate.Model -> Maybe String
createdToken model =
    Projection.createScreen model
        |> .created
        |> Maybe.map .token


createdFeedback : ApiKeyCreate.Model -> Maybe String
createdFeedback model =
    Projection.createScreen model
        |> .created
        |> Maybe.andThen .copyFeedback


copiedLabel : String
copiedLabel =
    I18n.en TidApiKeysCopied


createdBuild : CreatedApiKey
createdBuild =
    createdKey "key-3" "Build script" "calco_pat_build" "token-build" ReadWrite


createdKey : String -> String -> String -> String -> ApiKeyScope -> CreatedApiKey
createdKey id name hint token scope =
    { apiKey =
        { baseKey
            | id = id
            , name = name
            , tokenHint = hint
            , scope = scope
        }
    , token = token
    }


baseKey : ApiKey
baseKey =
    { id = ""
    , name = ""
    , tokenHint = ""
    , scope = Read
    , createdAt = "2026-10-26T11:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Nothing
    }
