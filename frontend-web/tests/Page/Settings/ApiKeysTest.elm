module Page.Settings.ApiKeysTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..))
import Data.Route exposing (Route(..))
import Expect
import Page.Settings.ApiKeys as ApiKeys
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Settings.ApiKeys"
        [ test "init requests keys and a successful load exposes their metadata" <|
            \_ ->
                { request = Tuple.second ApiKeys.init
                , loading = phase emptyModel
                , names = names loadedModel
                , dialog = dialogName loadedModel
                }
                    |> Expect.equal
                        { request = ApiKeys.RequestList
                        , loading = "loading"
                        , names = [ "Build script", "Phone shortcut" ]
                        , dialog = "none"
                        }
        , test "an empty list is a loaded page with no keys" <|
            \_ ->
                let
                    loaded : ApiKeys.Model
                    loaded =
                        step (ApiKeys.ApiKeysLoaded (Ok [])) emptyModel
                in
                { phase = phase loaded, names = names loaded }
                    |> Expect.equal { phase = "loaded", names = [] }
        , test "load failures show the error, retry starts fresh, and only 401 expires" <|
            \_ ->
                let
                    failed : ApiKeys.Model
                    failed =
                        step (ApiKeys.ApiKeysLoaded (Err Client.NetworkError)) emptyModel

                    forbidden : ApiKeys.Model
                    forbidden =
                        step (ApiKeys.ApiKeysLoaded (Err forbiddenError)) emptyModel
                in
                { phase = phase failed
                , error = loadError failed
                , retry = out ApiKeys.RetryClicked failed
                , retryLoaded = out ApiKeys.RetryClicked loadedModel
                , retryLoadedPhase = phase (step ApiKeys.RetryClicked loadedModel)
                , unauthorized = out (ApiKeys.ApiKeysLoaded (Err unauthorized)) emptyModel
                , forbidden = ( phase forbidden, loadError forbidden )
                , forbiddenOut = out (ApiKeys.ApiKeysLoaded (Err forbiddenError)) emptyModel
                }
                    |> Expect.equal
                        { phase = "failed"
                        , error = Just Client.NetworkError
                        , retry = ApiKeys.RequestList
                        , retryLoaded = ApiKeys.NoOp
                        , retryLoadedPhase = "loaded"
                        , unauthorized = ApiKeys.SessionExpired
                        , forbidden = ( "failed", Just forbiddenError )
                        , forbiddenOut = ApiKeys.NoOp
                        }
        , test "creating opens the create page instead of a dialog" <|
            \_ ->
                { out = out ApiKeys.CreateClicked loadedModel
                , dialog = dialogName (step ApiKeys.CreateClicked loadedModel)
                , names = names (step ApiKeys.CreateClicked loadedModel)
                }
                    |> Expect.equal
                        { out = ApiKeys.Navigate SettingsApiKeyCreate
                        , dialog = "none"
                        , names = [ "Build script", "Phone shortcut" ]
                        }
        , test "a refresh updates an open revoke dialog's key snapshot" <|
            \_ ->
                let
                    confirming : ApiKeys.Model
                    confirming =
                        step (ApiKeys.RevokeClicked firstKey) loadedModel

                    revoking : ApiKeys.Model
                    revoking =
                        step (ApiKeys.RevokeConfirmed firstKey) confirming

                    requestId : Int
                    requestId =
                        revokeRequestId confirming firstKey

                    failed : ApiKeys.Model
                    failed =
                        step
                            (ApiKeys.RevokeCompleted requestId firstKey (Err Client.NetworkError))
                            revoking

                    refreshedKey : ApiKey
                    refreshedKey =
                        { firstKey
                            | name = "Build script v2"
                            , tokenHint = "calco_pat_9999zzzz"
                        }

                    refreshed : ApiKeys.Model
                    refreshed =
                        step (ApiKeys.ApiKeysLoaded (Ok [ refreshedKey, secondKey ])) confirming

                    refreshedRevoking : ApiKeys.Model
                    refreshedRevoking =
                        step (ApiKeys.ApiKeysLoaded (Ok [ refreshedKey, secondKey ])) revoking

                    refreshedFailed : ApiKeys.Model
                    refreshedFailed =
                        step (ApiKeys.ApiKeysLoaded (Ok [ refreshedKey, secondKey ])) failed

                    refreshedThenFailed : ApiKeys.Model
                    refreshedThenFailed =
                        step
                            (ApiKeys.RevokeCompleted requestId firstKey (Err Client.NetworkError))
                            refreshedRevoking

                    refreshedRetryOut : ApiKeys.OutMsg
                    refreshedRetryOut =
                        out (ApiKeys.RevokeConfirmed firstKey) refreshedThenFailed
                in
                { dialog = dialogName refreshed
                , key = dialogKeyName refreshed
                , names = names refreshed
                , pendingDialog = dialogName refreshedRevoking
                , pendingKey = dialogKeyName refreshedRevoking
                , failedDialog = dialogName refreshedFailed
                , failedKey = dialogKeyName refreshedFailed
                , failedError = revokeError refreshedFailed
                , refreshedFailureDialog = dialogName refreshedThenFailed
                , refreshedFailureKey = dialogKeyName refreshedThenFailed
                , refreshedFailureError = revokeError refreshedThenFailed
                , refreshedRetry = refreshedRetryOut
                }
                    |> Expect.equal
                        { dialog = "confirm-revoke"
                        , key = Just "Build script v2"
                        , names = [ "Build script v2", "Phone shortcut" ]
                        , pendingDialog = "revoking"
                        , pendingKey = Just "Build script v2"
                        , failedDialog = "confirm-revoke"
                        , failedKey = Just "Build script v2"
                        , failedError = Just (Client.displayError Client.NetworkError)
                        , refreshedFailureDialog = "confirm-revoke"
                        , refreshedFailureKey = Just "Build script v2"
                        , refreshedFailureError = Just (Client.displayError Client.NetworkError)
                        , refreshedRetry = ApiKeys.RequestRevoke 2 refreshedKey
                        }
        , test "a refresh closes dialogs for keys removed from the list" <|
            \_ ->
                let
                    confirming : ApiKeys.Model
                    confirming =
                        step (ApiKeys.RevokeClicked firstKey) loadedModel

                    revoking : ApiKeys.Model
                    revoking =
                        step (ApiKeys.RevokeConfirmed firstKey) confirming

                    refreshed : ApiKeys.Model
                    refreshed =
                        step (ApiKeys.ApiKeysLoaded (Ok [ secondKey ])) confirming

                    refreshedRevoking : ApiKeys.Model
                    refreshedRevoking =
                        step (ApiKeys.ApiKeysLoaded (Ok [ secondKey ])) revoking
                in
                { confirmDialog = dialogName refreshed
                , confirmKey = dialogKeyName refreshed
                , confirmNames = names refreshed
                , revokeDialog = dialogName refreshedRevoking
                , revokeKey = dialogKeyName refreshedRevoking
                , revokeNames = names refreshedRevoking
                }
                    |> Expect.equal
                        { confirmDialog = "none"
                        , confirmKey = Nothing
                        , confirmNames = [ "Phone shortcut" ]
                        , revokeDialog = "none"
                        , revokeKey = Nothing
                        , revokeNames = [ "Phone shortcut" ]
                        }
        , test "revoking confirms, retries failures, and ignores wrong-key messages" <|
            \_ ->
                let
                    confirming : ApiKeys.Model
                    confirming =
                        step (ApiKeys.RevokeClicked firstKey) loadedModel

                    cancelled : ApiKeys.Model
                    cancelled =
                        step ApiKeys.RevokeCancelled confirming

                    revoking : ApiKeys.Model
                    revoking =
                        step (ApiKeys.RevokeConfirmed firstKey) confirming

                    firstRequestId : Int
                    firstRequestId =
                        revokeRequestId confirming firstKey

                    failed : ApiKeys.Model
                    failed =
                        step
                            (ApiKeys.RevokeCompleted
                                firstRequestId
                                firstKey
                                (Err Client.NetworkError)
                            )
                            revoking

                    retrying : ApiKeys.Model
                    retrying =
                        step (ApiKeys.RevokeConfirmed firstKey) failed

                    retryRequestId : Int
                    retryRequestId =
                        revokeRequestId failed firstKey

                    staleCompletion : ApiKeys.Model
                    staleCompletion =
                        step
                            (ApiKeys.RevokeCompleted firstRequestId firstKey (Ok ()))
                            retrying

                    revoked : ApiKeys.Model
                    revoked =
                        step
                            (ApiKeys.RevokeCompleted retryRequestId firstKey (Ok ()))
                            retrying

                    wrongConfirmOut : ApiKeys.OutMsg
                    wrongConfirmOut =
                        out (ApiKeys.RevokeConfirmed secondKey) confirming

                    wrongCompleted : ApiKeys.Model
                    wrongCompleted =
                        step (ApiKeys.RevokeCompleted firstRequestId secondKey (Ok ())) revoking

                    forbidden : ApiKeys.Model
                    forbidden =
                        step
                            (ApiKeys.RevokeCompleted
                                firstRequestId
                                firstKey
                                (Err forbiddenError)
                            )
                            revoking
                in
                { confirming = dialogName confirming
                , cancelled = dialogName cancelled
                , cancelledNames = names cancelled
                , request = out (ApiKeys.RevokeConfirmed firstKey) confirming
                , pending = dialogName revoking
                , failed = dialogName failed
                , failedError = revokeError failed
                , retry = out (ApiKeys.RevokeConfirmed firstKey) failed
                , idsDiffer = firstRequestId /= retryRequestId
                , staleCompletion = dialogName staleCompletion
                , staleNames = names staleCompletion
                , revoked = dialogName revoked
                , remaining = names revoked
                , wrongConfirm = wrongConfirmOut
                , wrongCompleted = dialogName wrongCompleted
                , wrongCompletedNames = names wrongCompleted
                , forbidden = dialogName forbidden
                , forbiddenError = revokeError forbidden
                , forbiddenOut =
                    out
                        (ApiKeys.RevokeCompleted firstRequestId firstKey (Err forbiddenError))
                        revoking
                , unauthorized =
                    out
                        (ApiKeys.RevokeCompleted firstRequestId firstKey (Err unauthorized))
                        revoking
                }
                    |> Expect.equal
                        { confirming = "confirm-revoke"
                        , cancelled = "none"
                        , cancelledNames = [ "Build script", "Phone shortcut" ]
                        , request = ApiKeys.RequestRevoke 1 firstKey
                        , pending = "revoking"
                        , failed = "confirm-revoke"
                        , failedError = Just (Client.displayError Client.NetworkError)
                        , retry = ApiKeys.RequestRevoke 2 firstKey
                        , idsDiffer = True
                        , staleCompletion = "revoking"
                        , staleNames = [ "Build script", "Phone shortcut" ]
                        , revoked = "none"
                        , remaining = [ "Phone shortcut" ]
                        , wrongConfirm = ApiKeys.NoOp
                        , wrongCompleted = "revoking"
                        , wrongCompletedNames = [ "Build script", "Phone shortcut" ]
                        , forbidden = "confirm-revoke"
                        , forbiddenError = Just (Client.displayError forbiddenError)
                        , forbiddenOut = ApiKeys.NoOp
                        , unauthorized = ApiKeys.SessionExpired
                        }
        ]



-- PROJECTION HELPERS


phase : ApiKeys.Model -> String
phase model =
    case model of
        ApiKeys.Loading ->
            "loading"

        ApiKeys.LoadFailed _ ->
            "failed"

        ApiKeys.Loaded _ ->
            "loaded"


names : ApiKeys.Model -> List String
names model =
    case model of
        ApiKeys.Loaded loaded ->
            List.map .name loaded.keys

        _ ->
            []


dialogName : ApiKeys.Model -> String
dialogName model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.NoDialog ->
                    "none"

                ApiKeys.ConfirmRevoke _ _ ->
                    "confirm-revoke"

                ApiKeys.Revoking _ _ ->
                    "revoking"

        _ ->
            "none"


dialogKeyName : ApiKeys.Model -> Maybe String
dialogKeyName model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.NoDialog ->
                    Nothing

                ApiKeys.ConfirmRevoke key _ ->
                    Just key.name

                ApiKeys.Revoking _ key ->
                    Just key.name

        _ ->
            Nothing


loadError : ApiKeys.Model -> Maybe Client.ApiError
loadError model =
    case model of
        ApiKeys.LoadFailed error ->
            Just error

        _ ->
            Nothing


revokeError : ApiKeys.Model -> Maybe String
revokeError model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.ConfirmRevoke _ maybeError ->
                    maybeError

                _ ->
                    Nothing

        _ ->
            Nothing


emptyModel : ApiKeys.Model
emptyModel =
    Tuple.first ApiKeys.init


loadedModel : ApiKeys.Model
loadedModel =
    step (ApiKeys.ApiKeysLoaded (Ok [ firstKey, secondKey ])) emptyModel


step : ApiKeys.Msg -> ApiKeys.Model -> ApiKeys.Model
step msg model =
    first (ApiKeys.update msg model)


revokeRequestId : ApiKeys.Model -> ApiKey -> Int
revokeRequestId model key =
    case out (ApiKeys.RevokeConfirmed key) model of
        ApiKeys.RequestRevoke requestId _ ->
            requestId

        _ ->
            0


out : ApiKeys.Msg -> ApiKeys.Model -> ApiKeys.OutMsg
out msg model =
    third (ApiKeys.update msg model)


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


forbiddenError : Client.ApiError
forbiddenError =
    Client.BadStatus 403 "insufficient_scope" "Insufficient scope"


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


firstKey : ApiKey
firstKey =
    { id = "key-1"
    , name = "Build script"
    , tokenHint = "calco_pat_1234abcd"
    , scope = Read
    , createdAt = "2026-10-26T10:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Just "2027-01-24T10:00:00Z"
    }


secondKey : ApiKey
secondKey =
    { id = "key-2"
    , name = "Phone shortcut"
    , tokenHint = "calco_pat_5678efgh"
    , scope = ReadWrite
    , createdAt = "2026-10-25T09:00:00Z"
    , lastUsedAt = Just "2026-10-25T09:30:00Z"
    , expiresAt = Nothing
    }
