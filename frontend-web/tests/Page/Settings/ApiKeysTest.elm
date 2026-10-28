module Page.Settings.ApiKeysTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..))
import Data.Route exposing (Route(..))
import Expect
import Page.Settings.ApiKeyProjection as Projection
import Page.Settings.ApiKeys as ApiKeys
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Settings.ApiKeys"
        [ test "load retry, create, and return refresh" <|
            \_ ->
                let
                    loading : ApiKeys.Model
                    loading =
                        Tuple.first ApiKeys.init

                    failed : ApiKeys.Model
                    failed =
                        step (ApiKeys.ApiKeysLoaded (Err Client.NetworkError)) loading

                    retried : ApiKeys.Model
                    retried =
                        step ApiKeys.RetryClicked failed

                    loaded : ApiKeys.Model
                    loaded =
                        step (ApiKeys.ApiKeysLoaded (Ok [ firstKey, secondKey ])) retried

                    returned : ApiKeys.Model
                    returned =
                        step
                            (ApiKeys.ApiKeysLoaded (Ok [ createdKey, firstKey, secondKey ]))
                            loaded

                    returnedScreen : Projection.ApiKeysScreen
                    returnedScreen =
                        Projection.apiKeysScreen returned
                in
                { failedError = (Projection.apiKeysScreen failed).error
                , retryOut = out ApiKeys.RetryClicked failed
                , loadedNames = (Projection.apiKeysScreen loaded).names
                , createOut = out ApiKeys.CreateClicked loaded
                , returnedNames = returnedScreen.names
                , finalOut =
                    out
                        (ApiKeys.ApiKeysLoaded (Ok [ createdKey, firstKey, secondKey ]))
                        loaded
                }
                    |> Expect.equal
                        { failedError = Just Fixtures.networkErrorMessage
                        , retryOut = ApiKeys.RequestList
                        , loadedNames = [ "Build script", "Phone shortcut" ]
                        , createOut = ApiKeys.Navigate SettingsApiKeyCreate
                        , returnedNames =
                            [ "Deploy script", "Build script", "Phone shortcut" ]
                        , finalOut = ApiKeys.NoOp
                        }
        , test "revoke cancels, fails, retries, ignores a late success, then expires" <|
            \_ ->
                let
                    loaded : ApiKeys.Model
                    loaded =
                        loadedModel

                    confirming : ApiKeys.Model
                    confirming =
                        step (ApiKeys.RevokeClicked firstKey) loaded

                    cancelled : ApiKeys.Model
                    cancelled =
                        step ApiKeys.RevokeCancelled confirming

                    reopened : ApiKeys.Model
                    reopened =
                        step (ApiKeys.RevokeClicked firstKey) cancelled
                in
                case requestRevoke (ApiKeys.RevokeConfirmed firstKey) reopened of
                    Err message ->
                        Expect.fail message

                    Ok ( revoking, requestId, keyName ) ->
                        let
                            failed : ApiKeys.Model
                            failed =
                                step
                                    (ApiKeys.RevokeCompleted
                                        requestId
                                        firstKey
                                        (Err Client.NetworkError)
                                    )
                                    revoking

                            retrying : ApiKeys.Model
                            retrying =
                                step (ApiKeys.RevokeConfirmed firstKey) failed
                        in
                        case requestRevoke (ApiKeys.RevokeConfirmed firstKey) failed of
                            Err message ->
                                Expect.fail message

                            Ok ( _, retryId, _ ) ->
                                let
                                    afterStale : ApiKeys.Model
                                    afterStale =
                                        step
                                            (ApiKeys.RevokeCompleted
                                                requestId
                                                firstKey
                                                (Ok ())
                                            )
                                            retrying
                                in
                                { confirmDialog = (Projection.apiKeysScreen confirming).dialog
                                , afterCancel = (Projection.apiKeysScreen cancelled).dialog
                                , requestedKey = Just keyName
                                , failedDialog = (Projection.apiKeysScreen failed).dialog
                                , wrongKeyOut =
                                    out (ApiKeys.RevokeConfirmed secondKey) failed
                                , staleDialog = (Projection.apiKeysScreen afterStale).dialog
                                , finalOut =
                                    out
                                        (ApiKeys.RevokeCompleted
                                            retryId
                                            firstKey
                                            (Err Fixtures.unauthorized)
                                        )
                                        retrying
                                }
                                    |> Expect.equal
                                        { confirmDialog =
                                            Just (Projection.confirmDialog "Build script" Nothing)
                                        , afterCancel = Nothing
                                        , requestedKey = Just "Build script"
                                        , failedDialog =
                                            Just
                                                (Projection.confirmDialog
                                                    "Build script"
                                                    (Just Fixtures.networkErrorMessage)
                                                )
                                        , wrongKeyOut = ApiKeys.NoOp
                                        , staleDialog =
                                            Just (Projection.revokingDialog "Build script")
                                        , finalOut = ApiKeys.SessionExpired
                                        }
        , test "a refresh updates an open dialog and closes it when the key is removed" <|
            \_ ->
                let
                    loaded : ApiKeys.Model
                    loaded =
                        loadedModel

                    confirming : ApiKeys.Model
                    confirming =
                        step (ApiKeys.RevokeClicked firstKey) loaded

                    refreshedKey : ApiKey
                    refreshedKey =
                        { firstKey | name = "Build script v2", tokenHint = "calco_pat_9999zzzz" }

                    refreshed : ApiKeys.Model
                    refreshed =
                        step (ApiKeys.ApiKeysLoaded (Ok [ refreshedKey, secondKey ])) confirming

                    revoking : ApiKeys.Model
                    revoking =
                        step (ApiKeys.RevokeConfirmed refreshedKey) refreshed

                    refreshedAgainKey : ApiKey
                    refreshedAgainKey =
                        { refreshedKey | name = "Build script v3" }

                    refreshedRevoking : ApiKeys.Model
                    refreshedRevoking =
                        step
                            (ApiKeys.ApiKeysLoaded (Ok [ refreshedAgainKey, secondKey ]))
                            revoking

                    removed : ApiKeys.Model
                    removed =
                        step (ApiKeys.ApiKeysLoaded (Ok [ secondKey ])) refreshedRevoking

                    removedScreen : Projection.ApiKeysScreen
                    removedScreen =
                        Projection.apiKeysScreen removed
                in
                { refreshedDialog = (Projection.apiKeysScreen refreshed).dialog
                , revokingDialog = (Projection.apiKeysScreen revoking).dialog
                , refreshedRevokingDialog =
                    (Projection.apiKeysScreen refreshedRevoking).dialog
                , removedNames = removedScreen.names
                , removedDialog = removedScreen.dialog
                , finalOut =
                    out (ApiKeys.ApiKeysLoaded (Ok [ secondKey ])) refreshedRevoking
                }
                    |> Expect.equal
                        { refreshedDialog =
                            Just (Projection.confirmDialog "Build script v2" Nothing)
                        , revokingDialog = Just (Projection.revokingDialog "Build script v2")
                        , refreshedRevokingDialog =
                            Just (Projection.revokingDialog "Build script v3")
                        , removedNames = [ "Phone shortcut" ]
                        , removedDialog = Nothing
                        , finalOut = ApiKeys.NoOp
                        }
        ]



-- EFFECTS AND HELPERS


requestRevoke :
    ApiKeys.Msg
    -> ApiKeys.Model
    -> Result String ( ApiKeys.Model, Int, String )
requestRevoke msg model =
    let
        ( next, _, outMsg ) =
            ApiKeys.update msg model
    in
    case outMsg of
        ApiKeys.RequestRevoke requestId key ->
            Ok ( next, requestId, key.name )

        _ ->
            Err "the revoke dialog did not emit RequestRevoke"


step : ApiKeys.Msg -> ApiKeys.Model -> ApiKeys.Model
step msg model =
    Fixtures.tupleFirst (ApiKeys.update msg model)


out : ApiKeys.Msg -> ApiKeys.Model -> ApiKeys.OutMsg
out msg model =
    Fixtures.tupleThird (ApiKeys.update msg model)


loadedModel : ApiKeys.Model
loadedModel =
    Tuple.first ApiKeys.init
        |> Story.runSteps step
            [ ApiKeys.ApiKeysLoaded (Ok [ firstKey, secondKey ]) ]



-- FIXTURES


firstKey : ApiKey
firstKey =
    apiKey "key-1" "Build script" "calco_pat_1234abcd" Read


secondKey : ApiKey
secondKey =
    apiKey "key-2" "Phone shortcut" "calco_pat_5678efgh" ReadWrite


createdKey : ApiKey
createdKey =
    apiKey "key-3" "Deploy script" "calco_pat_9012ijkl" ReadWrite


apiKey : String -> String -> String -> ApiKeyScope -> ApiKey
apiKey id name tokenHint scope =
    { baseKey | id = id, name = name, tokenHint = tokenHint, scope = scope }


baseKey : ApiKey
baseKey =
    { id = ""
    , name = ""
    , tokenHint = ""
    , scope = Read
    , createdAt = "2026-10-26T10:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Just "2027-01-24T10:00:00Z"
    }
