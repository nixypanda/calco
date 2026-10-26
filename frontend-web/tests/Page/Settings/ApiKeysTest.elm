module Page.Settings.ApiKeysTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..), CreatableScope(..), CreatedApiKey)
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
        , test "creating trims the name, reveals once, and reports copy success or failure" <|
            \_ ->
                let
                    opened : ApiKeys.Model
                    opened =
                        step ApiKeys.CreateClicked loadedModel

                    edited : ApiKeys.Model
                    edited =
                        opened
                            |> step (ApiKeys.CreateNameChanged "  Build script  ")
                            |> step (ApiKeys.CreateScopeChanged CreatableReadWrite)
                            |> step (ApiKeys.CreateExpiryChanged ApiKeys.NeverExpires)

                    submitted : ApiKeys.Model
                    submitted =
                        step ApiKeys.CreateSubmitted edited

                    requestId : Maybe Int
                    requestId =
                        pendingRequestId submitted

                    created : ApiKeys.Model
                    created =
                        step
                            (ApiKeys.CreateCompleted
                                (Maybe.withDefault 0 requestId)
                                (Ok createdKey)
                            )
                            submitted

                    copyPending : ApiKeys.Model
                    copyPending =
                        step ApiKeys.CopyClicked created

                    copyId : Maybe Int
                    copyId =
                        createdCopyRequestId copyPending

                    copySucceeded : ApiKeys.Model
                    copySucceeded =
                        step
                            (ApiKeys.CopyCompleted (Maybe.withDefault 0 copyId) True)
                            copyPending

                    copyFailed : ApiKeys.Model
                    copyFailed =
                        step
                            (ApiKeys.CopyCompleted (Maybe.withDefault 0 copyId) False)
                            copyPending

                    doneWhilePending : ApiKeys.Model
                    doneWhilePending =
                        step ApiKeys.CreatedDoneClicked copyPending

                    done : ApiKeys.Model
                    done =
                        step ApiKeys.CreatedDoneClicked copySucceeded

                    retryCreated : ApiKeys.Model
                    retryCreated =
                        step ApiKeys.RetryClicked created
                in
                { defaults =
                    createForm opened
                        |> Maybe.map
                            (\form ->
                                ( form.scope, form.expiry, createStateName form.state )
                            )
                , request =
                    out ApiKeys.CreateSubmitted edited
                        |> requestSummary
                , pending = createForm submitted |> Maybe.map (.state >> createStateName)
                , createdDialog = dialogName created
                , createdToken = createdToken created
                , createdNames = names created
                , copy = out ApiKeys.CopyClicked created |> copySummary
                , copyPending = createdCopyState copyPending
                , copySucceeded = createdCopyState copySucceeded
                , copyFailed = createdCopyState copyFailed
                , doneWhilePending = dialogName doneWhilePending
                , doneWhilePendingToken = createdToken doneWhilePending
                , retryCreated = dialogName retryCreated
                , retryCreatedToken = createdToken retryCreated
                , doneDialog = dialogName done
                , doneToken = createdToken done
                , doneNames = names done
                }
                    |> Expect.equal
                        { defaults = Just ( CreatableRead, ApiKeys.ExpireInDays 90, "editing" )
                        , request =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiresInDays = Nothing
                                }
                        , pending = Just "submitting"
                        , createdDialog = "created"
                        , createdToken = Just "token-once"
                        , createdNames = [ "New script", "Build script", "Phone shortcut" ]
                        , copy = Maybe.map (\id -> ( id, "token-once" )) copyId
                        , copyPending = "pending"
                        , copySucceeded = "succeeded"
                        , copyFailed = "failed"
                        , doneWhilePending = "created"
                        , doneWhilePendingToken = Just "token-once"
                        , retryCreated = "created"
                        , retryCreatedToken = Just "token-once"
                        , doneDialog = "none"
                        , doneToken = Nothing
                        , doneNames = [ "New script", "Build script", "Phone shortcut" ]
                        }
        , test "names up to 64 characters are accepted and 65 are rejected" <|
            \_ ->
                let
                    opened : ApiKeys.Model
                    opened =
                        step ApiKeys.CreateClicked loadedModel

                    missingName : ApiKeys.Model
                    missingName =
                        step ApiKeys.CreateSubmitted opened

                    overlongName : ApiKeys.Model
                    overlongName =
                        opened
                            |> step (ApiKeys.CreateNameChanged (String.repeat 65 "a"))
                            |> step ApiKeys.CreateSubmitted

                    longestName : String
                    longestName =
                        String.repeat 64 "a"

                    longestEdited : ApiKeys.Model
                    longestEdited =
                        opened
                            |> step (ApiKeys.CreateNameChanged longestName)

                    longestValid : ApiKeys.Model
                    longestValid =
                        longestEdited
                            |> step ApiKeys.CreateSubmitted

                    edited : ApiKeys.Model
                    edited =
                        step (ApiKeys.CreateNameChanged "Usable") missingName
                in
                { missingOut = out ApiKeys.CreateSubmitted opened
                , missing = createForm missingName |> Maybe.map (.state >> createStateName)
                , overlong = createForm overlongName |> Maybe.map (.state >> createStateName)
                , longest = out ApiKeys.CreateSubmitted longestEdited |> requestSummary
                , longestState =
                    createForm longestValid |> Maybe.map (.state >> createStateName)
                , edited = createForm edited |> Maybe.map (.state >> createStateName)
                }
                    |> Expect.equal
                        { missingOut = ApiKeys.NoOp
                        , missing = Just "invalid"
                        , overlong = Just "invalid"
                        , longest =
                            Just
                                { name = longestName
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , longestState = Just "submitting"
                        , edited = Just "editing"
                        }
        , test "a failed create keeps the form open and only 401 expires" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step ApiKeys.CreateSubmitted

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    failed : ApiKeys.Model
                    failed =
                        step
                            (ApiKeys.CreateCompleted requestId (Err Client.NetworkError))
                            submitted

                    forbidden : ApiKeys.Model
                    forbidden =
                        step
                            (ApiKeys.CreateCompleted requestId (Err forbiddenError))
                            submitted
                in
                { failed = createForm failed |> Maybe.map (.state >> createStateName)
                , failedError = createForm failed |> Maybe.andThen failedMessage
                , failedOut =
                    out
                        (ApiKeys.CreateCompleted requestId (Err Client.NetworkError))
                        submitted
                , forbidden = createForm forbidden |> Maybe.andThen failedMessage
                , forbiddenOut =
                    out (ApiKeys.CreateCompleted requestId (Err forbiddenError)) submitted
                , unauthorized =
                    out
                        (ApiKeys.CreateCompleted requestId (Err unauthorized))
                        submitted
                }
                    |> Expect.equal
                        { failed = Just "failed"
                        , failedError = Just (Client.displayError Client.NetworkError)
                        , failedOut = ApiKeys.NoOp
                        , forbidden = Just (Client.displayError forbiddenError)
                        , forbiddenOut = ApiKeys.NoOp
                        , unauthorized = ApiKeys.SessionExpired
                        }
        , test "editing fields while a create is pending is ignored" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step (ApiKeys.CreateScopeChanged CreatableReadWrite)
                            |> step (ApiKeys.CreateExpiryChanged ApiKeys.NeverExpires)
                            |> step ApiKeys.CreateSubmitted

                    edited : ApiKeys.Model
                    edited =
                        submitted
                            |> step (ApiKeys.CreateNameChanged "Renamed")
                            |> step (ApiKeys.CreateScopeChanged CreatableRead)
                            |> step (ApiKeys.CreateExpiryChanged (ApiKeys.ExpireInDays 30))

                    cancelAttempt : ApiKeys.Model
                    cancelAttempt =
                        step ApiKeys.CreateCancelled edited

                    requestId : Int
                    requestId =
                        pendingRequestId edited |> Maybe.withDefault 0

                    created : ApiKeys.Model
                    created =
                        step
                            (ApiKeys.CreateCompleted requestId (Ok createdKey))
                            edited
                in
                { form =
                    createForm edited
                        |> Maybe.map
                            (\form ->
                                { name = form.name
                                , scope = form.scope
                                , expiry = form.expiry
                                , state = createStateName form.state
                                }
                            )
                , cancelDialog = dialogName cancelAttempt
                , dialog = dialogName created
                , token = createdToken created
                }
                    |> Expect.equal
                        { form =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiry = ApiKeys.NeverExpires
                                , state = "submitting"
                                }
                        , cancelDialog = "creating"
                        , dialog = "created"
                        , token = Just "token-once"
                        }
        , test "submitting again while a create is pending does not issue a second request" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step ApiKeys.CreateSubmitted

                    resubmitted : ApiKeys.Model
                    resubmitted =
                        submitted
                            |> step (ApiKeys.CreateNameChanged "Renamed")
                            |> step ApiKeys.CreateSubmitted
                in
                { out = out ApiKeys.CreateSubmitted resubmitted
                , requestId = pendingRequestId resubmitted
                , names = names resubmitted
                }
                    |> Expect.equal
                        { out = ApiKeys.NoOp
                        , requestId = pendingRequestId submitted
                        , names = [ "Build script", "Phone shortcut" ]
                        }
        , test "stale or duplicate create completions cannot replace another dialog" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step ApiKeys.CreateSubmitted

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    created : ApiKeys.Model
                    created =
                        step (ApiKeys.CreateCompleted requestId (Ok createdKey)) submitted

                    duplicate : ApiKeys.Model
                    duplicate =
                        step
                            (ApiKeys.CreateCompleted requestId (Ok otherCreatedKey))
                            created

                    blocked : ApiKeys.Model
                    blocked =
                        duplicate
                            |> step (ApiKeys.RevokeClicked firstKey)
                            |> step ApiKeys.CreateClicked

                    reopened : ApiKeys.Model
                    reopened =
                        duplicate
                            |> step ApiKeys.CreatedDoneClicked
                            |> step ApiKeys.CreateClicked

                    stale : ApiKeys.Model
                    stale =
                        step
                            (ApiKeys.CreateCompleted requestId (Ok otherCreatedKey))
                            reopened

                    wrongPending : ApiKeys.Model
                    wrongPending =
                        step
                            (ApiKeys.CreateCompleted (requestId + 1) (Ok otherCreatedKey))
                            submitted
                in
                { duplicateToken = createdToken duplicate
                , duplicateNames = names duplicate
                , blockedDialog = dialogName blocked
                , blockedToken = createdToken blocked
                , reopenedDialog = dialogName reopened
                , staleDialog = dialogName stale
                , staleNames = names stale
                , wrongToken = createdToken wrongPending
                , wrongState =
                    createForm wrongPending |> Maybe.map (.state >> createStateName)
                }
                    |> Expect.equal
                        { duplicateToken = Just "token-once"
                        , duplicateNames = [ "New script", "Build script", "Phone shortcut" ]
                        , blockedDialog = "created"
                        , blockedToken = Just "token-once"
                        , reopenedDialog = "creating"
                        , staleDialog = "creating"
                        , staleNames = [ "New script", "Build script", "Phone shortcut" ]
                        , wrongToken = Nothing
                        , wrongState = Just "submitting"
                        }
        , test "a list refresh preserves pending and created rows without duplicates" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step ApiKeys.CreateSubmitted

                    refreshedPending : ApiKeys.Model
                    refreshedPending =
                        step (ApiKeys.ApiKeysLoaded (Ok [ firstKey ])) submitted

                    requestId : Int
                    requestId =
                        pendingRequestId refreshedPending |> Maybe.withDefault 0

                    created : ApiKeys.Model
                    created =
                        step
                            (ApiKeys.CreateCompleted requestId (Ok createdKey))
                            refreshedPending

                    refreshedWithout : ApiKeys.Model
                    refreshedWithout =
                        step (ApiKeys.ApiKeysLoaded (Ok [ firstKey ])) created

                    refreshedWith : ApiKeys.Model
                    refreshedWith =
                        step
                            (ApiKeys.ApiKeysLoaded
                                (Ok [ firstKey, createdKey.apiKey ])
                            )
                            created
                in
                { pendingName = createForm refreshedPending |> Maybe.map .name
                , pendingState =
                    createForm refreshedPending |> Maybe.map (.state >> createStateName)
                , createdDialog = dialogName refreshedWithout
                , createdToken = createdToken refreshedWithout
                , withoutNames = names refreshedWithout
                , withNames = names refreshedWith
                }
                    |> Expect.equal
                        { pendingName = Just "Build script"
                        , pendingState = Just "submitting"
                        , createdDialog = "created"
                        , createdToken = Just "token-once"
                        , withoutNames = [ "New script", "Build script" ]
                        , withNames = [ "New script", "Build script" ]
                        }
        , test "a create completion after a refresh containing the key does not duplicate it" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "New script")
                            |> step ApiKeys.CreateSubmitted

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    refreshed : ApiKeys.Model
                    refreshed =
                        step
                            (ApiKeys.ApiKeysLoaded
                                (Ok [ firstKey, createdKey.apiKey ])
                            )
                            submitted

                    completed : ApiKeys.Model
                    completed =
                        step
                            (ApiKeys.CreateCompleted requestId (Ok createdKey))
                            refreshed
                in
                { names = names completed
                , count = List.length (names completed)
                }
                    |> Expect.equal
                        { names = [ "New script", "Build script" ]
                        , count = 2
                        }
        , test "a delayed copy result cannot affect a new dialog" <|
            \_ ->
                let
                    submitted : ApiKeys.Model
                    submitted =
                        loadedModel
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Build script")
                            |> step ApiKeys.CreateSubmitted

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    created : ApiKeys.Model
                    created =
                        step (ApiKeys.CreateCompleted requestId (Ok createdKey)) submitted

                    copyPending : ApiKeys.Model
                    copyPending =
                        step ApiKeys.CopyClicked created

                    oldCopyId : Int
                    oldCopyId =
                        createdCopyRequestId copyPending |> Maybe.withDefault 0

                    copySucceeded : ApiKeys.Model
                    copySucceeded =
                        step (ApiKeys.CopyCompleted oldCopyId True) copyPending

                    nextSubmitted : ApiKeys.Model
                    nextSubmitted =
                        copySucceeded
                            |> step ApiKeys.CreatedDoneClicked
                            |> step ApiKeys.CreateClicked
                            |> step (ApiKeys.CreateNameChanged "Other script")
                            |> step ApiKeys.CreateSubmitted

                    nextRequestId : Int
                    nextRequestId =
                        pendingRequestId nextSubmitted |> Maybe.withDefault 0

                    nextCreated : ApiKeys.Model
                    nextCreated =
                        step
                            (ApiKeys.CreateCompleted nextRequestId (Ok otherCreatedKey))
                            nextSubmitted

                    nextCopyPending : ApiKeys.Model
                    nextCopyPending =
                        step ApiKeys.CopyClicked nextCreated

                    nextCopyId : Maybe Int
                    nextCopyId =
                        createdCopyRequestId nextCopyPending

                    staleCopyResult : ApiKeys.Model
                    staleCopyResult =
                        step
                            (ApiKeys.CopyCompleted oldCopyId False)
                            nextCopyPending

                    newCopyResult : ApiKeys.Model
                    newCopyResult =
                        step
                            (ApiKeys.CopyCompleted (Maybe.withDefault 0 nextCopyId) True)
                            staleCopyResult
                in
                { staleToken = createdToken staleCopyResult
                , staleCopyState = createdCopyState staleCopyResult
                , newCopyState = createdCopyState newCopyResult
                }
                    |> Expect.equal
                        { staleToken = Just "other-token"
                        , staleCopyState = "pending"
                        , newCopyState = "succeeded"
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

                    failed : ApiKeys.Model
                    failed =
                        step
                            (ApiKeys.RevokeCompleted firstKey (Err Client.NetworkError))
                            revoking

                    retrying : ApiKeys.Model
                    retrying =
                        step (ApiKeys.RevokeConfirmed firstKey) failed

                    revoked : ApiKeys.Model
                    revoked =
                        step (ApiKeys.RevokeCompleted firstKey (Ok ())) retrying

                    wrongConfirmOut : ApiKeys.OutMsg
                    wrongConfirmOut =
                        out (ApiKeys.RevokeConfirmed secondKey) confirming

                    wrongCompleted : ApiKeys.Model
                    wrongCompleted =
                        step (ApiKeys.RevokeCompleted secondKey (Ok ())) revoking

                    forbidden : ApiKeys.Model
                    forbidden =
                        step
                            (ApiKeys.RevokeCompleted firstKey (Err forbiddenError))
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
                , revoked = dialogName revoked
                , remaining = names revoked
                , wrongConfirm = wrongConfirmOut
                , wrongCompleted = dialogName wrongCompleted
                , wrongCompletedNames = names wrongCompleted
                , forbidden = dialogName forbidden
                , forbiddenError = revokeError forbidden
                , forbiddenOut =
                    out (ApiKeys.RevokeCompleted firstKey (Err forbiddenError)) revoking
                , unauthorized =
                    out (ApiKeys.RevokeCompleted firstKey (Err unauthorized)) revoking
                }
                    |> Expect.equal
                        { confirming = "confirm-revoke"
                        , cancelled = "none"
                        , cancelledNames = [ "Build script", "Phone shortcut" ]
                        , request = ApiKeys.RequestRevoke firstKey
                        , pending = "revoking"
                        , failed = "confirm-revoke"
                        , failedError = Just (Client.displayError Client.NetworkError)
                        , retry = ApiKeys.RequestRevoke firstKey
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

                ApiKeys.Creating _ ->
                    "creating"

                ApiKeys.Created _ _ ->
                    "created"

                ApiKeys.ConfirmRevoke _ _ ->
                    "confirm-revoke"

                ApiKeys.Revoking _ ->
                    "revoking"

        _ ->
            "none"


createForm : ApiKeys.Model -> Maybe ApiKeys.CreateForm
createForm model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.Creating form ->
                    Just form

                _ ->
                    Nothing

        _ ->
            Nothing


pendingRequestId : ApiKeys.Model -> Maybe Int
pendingRequestId model =
    createForm model
        |> Maybe.andThen
            (\form ->
                case form.state of
                    ApiKeys.Submitting requestId ->
                        Just requestId

                    _ ->
                        Nothing
            )


createStateName : ApiKeys.CreateState -> String
createStateName state =
    case state of
        ApiKeys.Editing ->
            "editing"

        ApiKeys.Invalid _ ->
            "invalid"

        ApiKeys.Submitting _ ->
            "submitting"

        ApiKeys.Failed _ ->
            "failed"


failedMessage : ApiKeys.CreateForm -> Maybe String
failedMessage form =
    case form.state of
        ApiKeys.Failed message ->
            Just message

        _ ->
            Nothing


requestSummary :
    ApiKeys.OutMsg
    -> Maybe { name : String, scope : CreatableScope, expiresInDays : Maybe Int }
requestSummary outMsg =
    case outMsg of
        ApiKeys.RequestCreate _ request ->
            Just request

        _ ->
            Nothing


copySummary : ApiKeys.OutMsg -> Maybe ( Int, String )
copySummary outMsg =
    case outMsg of
        ApiKeys.CopyText copyId token ->
            Just ( copyId, token )

        _ ->
            Nothing


createdCopyRequestId : ApiKeys.Model -> Maybe Int
createdCopyRequestId model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.Created _ (ApiKeys.CopyPending copyId) ->
                    Just copyId

                _ ->
                    Nothing

        _ ->
            Nothing


createdToken : ApiKeys.Model -> Maybe String
createdToken model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.Created created _ ->
                    Just created.token

                _ ->
                    Nothing

        _ ->
            Nothing


createdCopyState : ApiKeys.Model -> String
createdCopyState model =
    case model of
        ApiKeys.Loaded loaded ->
            case loaded.dialog of
                ApiKeys.Created _ copyState ->
                    case copyState of
                        ApiKeys.CopyIdle ->
                            "idle"

                        ApiKeys.CopyPending _ ->
                            "pending"

                        ApiKeys.CopySucceeded ->
                            "succeeded"

                        ApiKeys.CopyFailed ->
                            "failed"

                _ ->
                    "none"

        _ ->
            "none"


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


createdKey : CreatedApiKey
createdKey =
    { apiKey =
        { id = "key-3"
        , name = "New script"
        , tokenHint = "calco_pat_9012ijkl"
        , scope = ReadWrite
        , createdAt = "2026-10-26T11:00:00Z"
        , lastUsedAt = Nothing
        , expiresAt = Nothing
        }
    , token = "token-once"
    }


otherCreatedKey : CreatedApiKey
otherCreatedKey =
    { apiKey =
        { id = "key-4"
        , name = "Other script"
        , tokenHint = "calco_pat_3456mnop"
        , scope = Read
        , createdAt = "2026-10-26T12:00:00Z"
        , lastUsedAt = Nothing
        , expiresAt = Nothing
        }
    , token = "other-token"
    }
