module Page.Settings.ApiKeysTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..))
import Data.Route exposing (Route(..))
import Expect
import Page.Settings.ApiKeys as ApiKeys
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Settings.ApiKeys"
        [ test "a user retries a failed load and opens create" <|
            \_ ->
                Story.start ( ApiKeys.init |> Tuple.first, ApiKeys.init |> Tuple.second )
                    |> step (ApiKeys.ApiKeysLoaded (Err Client.NetworkError))
                    |> step ApiKeys.RetryClicked
                    |> step (ApiKeys.ApiKeysLoaded (Ok [ firstKey, secondKey ]))
                    |> step ApiKeys.CreateClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (ApiKeys.Navigate SettingsApiKeyCreate)
                        )
        , test "a user revokes a key" <|
            \_ ->
                loaded
                    |> step (ApiKeys.RevokeClicked firstKey)
                    |> step (ApiKeys.RevokeConfirmed firstKey)
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeys.RequestRevoke requestId key ->
                                    Ok
                                        (ApiKeys.RevokeCompleted requestId
                                            key
                                            (Err Client.NetworkError)
                                        )

                                _ ->
                                    Err "expected a revoke request"
                        )
                    |> step (ApiKeys.RevokeConfirmed firstKey)
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                ApiKeys.RequestRevoke requestId key ->
                                    Ok
                                        (ApiKeys.RevokeCompleted requestId
                                            key
                                            (Err Fixtures.unauthorized)
                                        )

                                _ ->
                                    Err "expected a revoke request"
                        )
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal ApiKeys.SessionExpired
                        )
        , test "a refresh removes a revoked key and closes its dialog" <|
            \_ ->
                loaded
                    |> step (ApiKeys.RevokeClicked firstKey)
                    |> step (ApiKeys.ApiKeysLoaded (Ok [ secondKey ]))
                    |> finish
                        (\( model, outMsg ) ->
                            { names = keyNames model
                            , dialog = keyDialog model
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { names = [ "Phone shortcut" ]
                                    , dialog = Nothing
                                    , finalOut = ApiKeys.NoOp
                                    }
                        )
        ]


stepWithOut :
    ApiKeys.Msg
    -> ApiKeys.Model
    -> ( ApiKeys.Model, ApiKeys.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            ApiKeys.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey ApiKeys.Model ApiKeys.OutMsg


step : ApiKeys.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


bind :
    (ApiKeys.OutMsg -> Result String ApiKeys.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind stepWithOut


finish :
    (( ApiKeys.Model, ApiKeys.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loaded : Journey
loaded =
    Story.start ( ApiKeys.init |> Tuple.first, ApiKeys.init |> Tuple.second )
        |> step (ApiKeys.ApiKeysLoaded (Ok [ firstKey, secondKey ]))


keyNames : ApiKeys.Model -> List String
keyNames model =
    case model of
        ApiKeys.Loaded loadedModel ->
            List.map .name loadedModel.keys

        _ ->
            []


keyDialog : ApiKeys.Model -> Maybe String
keyDialog model =
    case model of
        ApiKeys.Loaded loadedModel ->
            case loadedModel.dialog of
                ApiKeys.NoDialog ->
                    Nothing

                ApiKeys.ConfirmRevoke key _ ->
                    Just key.name

                ApiKeys.Revoking _ key ->
                    Just key.name

        _ ->
            Nothing



-- FIXTURES


firstKey : ApiKey
firstKey =
    apiKey "key-1" "Build script" "calco_pat_1234abcd" Read


secondKey : ApiKey
secondKey =
    apiKey "key-2" "Phone shortcut" "calco_pat_5678efgh" ReadWrite


apiKey : String -> String -> String -> ApiKeyScope -> ApiKey
apiKey id name tokenHint scope =
    { id = id
    , name = name
    , tokenHint = tokenHint
    , scope = scope
    , createdAt = "2026-10-26T10:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Just "2027-01-24T10:00:00Z"
    }
