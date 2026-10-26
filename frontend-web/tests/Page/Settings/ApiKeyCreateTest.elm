module Page.Settings.ApiKeyCreateTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKeyScope(..), CreatableScope(..), CreateRequest, CreatedApiKey)
import Data.Route exposing (Route(..))
import Expect
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Settings.ApiKeyCreate"
        [ test "submitting an untouched form sends read scope and a 90-day expiry" <|
            \_ ->
                let
                    named : ApiKeyCreate.Model
                    named =
                        step (ApiKeyCreate.NameChanged "Default script") emptyModel

                    submitted : ApiKeyCreate.Model
                    submitted =
                        step ApiKeyCreate.Submitted named
                in
                { request = out ApiKeyCreate.Submitted named |> requestSummary
                , requestId = pendingRequestId submitted
                }
                    |> Expect.equal
                        { request =
                            Just
                                { name = "Default script"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , requestId = Just 1
                        }
        , test "creating trims the name and sends the selected scope and expiry" <|
            \_ ->
                let
                    edited : ApiKeyCreate.Model
                    edited =
                        emptyModel
                            |> step (ApiKeyCreate.NameChanged "  Build script  ")
                            |> step (ApiKeyCreate.ScopeChanged CreatableReadWrite)
                            |> step (ApiKeyCreate.ExpiryChanged ApiKeyCreate.NeverExpires)

                    submitted : ApiKeyCreate.Model
                    submitted =
                        step ApiKeyCreate.Submitted edited

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    created : ApiKeyCreate.Model
                    created =
                        step
                            (ApiKeyCreate.CreateCompleted requestId (Ok createdKey))
                            submitted
                in
                { request = out ApiKeyCreate.Submitted edited |> requestSummary
                , pending = formSummary submitted
                , requestId = pendingRequestId submitted
                , phase = phase created
                , token = createdToken created
                }
                    |> Expect.equal
                        { request =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiresInDays = Nothing
                                }
                        , pending =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiry = ApiKeyCreate.NeverExpires
                                , state = "submitting"
                                }
                        , requestId = Just 1
                        , phase = "created"
                        , token = Just "token-once"
                        }
        , test "copy state gates Done and reports success or failure" <|
            \_ ->
                let
                    created : ApiKeyCreate.Model
                    created =
                        makeCreated "Build script"

                    copyPending : ApiKeyCreate.Model
                    copyPending =
                        step ApiKeyCreate.CopyClicked created

                    copyId : Int
                    copyId =
                        copyPendingId copyPending |> Maybe.withDefault 0

                    copySucceeded : ApiKeyCreate.Model
                    copySucceeded =
                        step (ApiKeyCreate.CopyCompleted copyId True) copyPending

                    copyFailed : ApiKeyCreate.Model
                    copyFailed =
                        step (ApiKeyCreate.CopyCompleted copyId False) copyPending

                    resubmittedCopy : ApiKeyCreate.Model
                    resubmittedCopy =
                        step ApiKeyCreate.CopyClicked copyPending

                    doneWhilePending : ApiKeyCreate.Model
                    doneWhilePending =
                        step ApiKeyCreate.DoneClicked copyPending

                    done : ApiKeyCreate.Model
                    done =
                        step ApiKeyCreate.DoneClicked copySucceeded
                in
                { copy = out ApiKeyCreate.CopyClicked created |> copySummary
                , copyState = copyStateName copyPending
                , pendingCopyId = copyPendingId copyPending
                , resubmitted = out ApiKeyCreate.CopyClicked copyPending
                , resubmittedState = copyStateName resubmittedCopy
                , succeeded = copyStateName copySucceeded
                , failed = copyStateName copyFailed
                , doneWhilePending = out ApiKeyCreate.DoneClicked copyPending
                , doneWhilePendingState = phase doneWhilePending
                , doneWhilePendingToken = createdToken doneWhilePending
                , done = out ApiKeyCreate.DoneClicked copySucceeded
                , doneState = phase done
                , doneToken = createdToken done
                }
                    |> Expect.equal
                        { copy = Just ( 2, "token-once" )
                        , copyState = "pending"
                        , pendingCopyId = Just 2
                        , resubmitted = ApiKeyCreate.NoOp
                        , resubmittedState = "pending"
                        , succeeded = "succeeded"
                        , failed = "failed"
                        , doneWhilePending = ApiKeyCreate.NoOp
                        , doneWhilePendingState = "created"
                        , doneWhilePendingToken = Just "token-once"
                        , done = ApiKeyCreate.Navigate SettingsApiKeys
                        , doneState = "created"
                        , doneToken = Just "token-once"
                        }
        , test "names are required, capped at 64 characters, and editing clears validation" <|
            \_ ->
                let
                    missingName : ApiKeyCreate.Model
                    missingName =
                        step ApiKeyCreate.Submitted emptyModel

                    overlongName : ApiKeyCreate.Model
                    overlongName =
                        emptyModel
                            |> step (ApiKeyCreate.NameChanged (String.repeat 65 "a"))
                            |> step ApiKeyCreate.Submitted

                    longestName : String
                    longestName =
                        String.repeat 64 "a"

                    longestEdited : ApiKeyCreate.Model
                    longestEdited =
                        step (ApiKeyCreate.NameChanged longestName) emptyModel

                    longestValid : ApiKeyCreate.Model
                    longestValid =
                        step ApiKeyCreate.Submitted longestEdited

                    edited : ApiKeyCreate.Model
                    edited =
                        step (ApiKeyCreate.NameChanged "Usable") missingName
                in
                { missingOut = out ApiKeyCreate.Submitted emptyModel
                , missing = formSummary missingName
                , overlong = formSummary overlongName
                , longest = out ApiKeyCreate.Submitted longestEdited |> requestSummary
                , longestState = formSummary longestValid
                , edited = formSummary edited
                }
                    |> Expect.equal
                        { missingOut = ApiKeyCreate.NoOp
                        , missing =
                            Just
                                { name = ""
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "invalid"
                                }
                        , overlong =
                            Just
                                { name = String.repeat 65 "a"
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "invalid"
                                }
                        , longest =
                            Just
                                { name = longestName
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , longestState =
                            Just
                                { name = longestName
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "submitting"
                                }
                        , edited =
                            Just
                                { name = "Usable"
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "editing"
                                }
                        }
        , test "a failed create keeps the form open and only 401 expires" <|
            \_ ->
                let
                    submitted : ApiKeyCreate.Model
                    submitted =
                        startCreate "Build script"

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    failed : ApiKeyCreate.Model
                    failed =
                        step
                            (ApiKeyCreate.CreateCompleted requestId (Err Client.NetworkError))
                            submitted

                    forbidden : ApiKeyCreate.Model
                    forbidden =
                        step
                            (ApiKeyCreate.CreateCompleted requestId (Err forbiddenError))
                            submitted
                in
                { failed = formSummary failed
                , failedError = failedMessage failed
                , failedOut =
                    out
                        (ApiKeyCreate.CreateCompleted requestId (Err Client.NetworkError))
                        submitted
                , forbidden = failedMessage forbidden
                , forbiddenOut =
                    out (ApiKeyCreate.CreateCompleted requestId (Err forbiddenError)) submitted
                , unauthorized =
                    out
                        (ApiKeyCreate.CreateCompleted requestId (Err unauthorized))
                        submitted
                , retried = out ApiKeyCreate.Submitted failed |> requestSummary
                }
                    |> Expect.equal
                        { failed =
                            Just
                                { name = "Build script"
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "failed"
                                }
                        , failedError = Just (Client.displayError Client.NetworkError)
                        , failedOut = ApiKeyCreate.NoOp
                        , forbidden = Just (Client.displayError forbiddenError)
                        , forbiddenOut = ApiKeyCreate.NoOp
                        , unauthorized = ApiKeyCreate.SessionExpired
                        , retried =
                            Just
                                { name = "Build script"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        }
        , test "retrying a failed create issues a new request id and can complete" <|
            \_ ->
                let
                    submitted : ApiKeyCreate.Model
                    submitted =
                        startCreate "Build script"

                    firstRequestId : Int
                    firstRequestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    failed : ApiKeyCreate.Model
                    failed =
                        step
                            (ApiKeyCreate.CreateCompleted firstRequestId (Err Client.NetworkError))
                            submitted

                    retried : ApiKeyCreate.Model
                    retried =
                        step ApiKeyCreate.Submitted failed

                    retriedRequestId : Int
                    retriedRequestId =
                        pendingRequestId retried |> Maybe.withDefault 0

                    completed : ApiKeyCreate.Model
                    completed =
                        step
                            (ApiKeyCreate.CreateCompleted retriedRequestId (Ok createdKey))
                            retried
                in
                { firstRequestId = firstRequestId
                , failedState = formSummary failed |> Maybe.map .state
                , retriedRequest = out ApiKeyCreate.Submitted failed |> requestSummary
                , retriedRequestId = retriedRequestId
                , idsDiffer = firstRequestId /= retriedRequestId
                , completedPhase = phase completed
                , token = createdToken completed
                }
                    |> Expect.equal
                        { firstRequestId = 1
                        , failedState = Just "failed"
                        , retriedRequest =
                            Just
                                { name = "Build script"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , retriedRequestId = 2
                        , idsDiffer = True
                        , completedPhase = "created"
                        , token = Just "token-once"
                        }
        , test "name validation trims like Rust and rejects invisible and forbidden code points" <|
            \_ ->
                let
                    validationFor : String -> Maybe ApiKeyCreate.CreateError
                    validationFor name =
                        emptyModel
                            |> step (ApiKeyCreate.NameChanged name)
                            |> step ApiKeyCreate.Submitted
                            |> validationError

                    requestFor : String -> Maybe CreateRequest
                    requestFor name =
                        out ApiKeyCreate.Submitted
                            (step (ApiKeyCreate.NameChanged name) emptyModel)
                            |> requestSummary

                    emoji64 : String
                    emoji64 =
                        String.repeat 64 "😀"

                    emoji65 : String
                    emoji65 =
                        String.repeat 65 "😀"
                in
                { whitespace = validationFor "   "
                , invisible = validationFor "\u{200C}\u{200D}"
                , forbidden = validationFor "bad\u{202E}name"
                , control = validationFor "bad\nname"
                , trailingBom = validationFor "Build\u{FEFF}"
                , leadingNextLine = requestFor "\u{0085}Build"
                , trailingNextLine = requestFor "Build\u{0085}"
                , emoji64 = requestFor emoji64
                , emoji65 = validationFor emoji65
                }
                    |> Expect.equal
                        { whitespace = Just ApiKeyCreate.NameRequired
                        , invisible = Just ApiKeyCreate.NameInvalid
                        , forbidden = Just ApiKeyCreate.NameInvalid
                        , control = Just ApiKeyCreate.NameInvalid
                        , trailingBom = Just ApiKeyCreate.NameInvalid
                        , leadingNextLine =
                            Just
                                { name = "Build"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , trailingNextLine =
                            Just
                                { name = "Build"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , emoji64 =
                            Just
                                { name = emoji64
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , emoji65 = Just ApiKeyCreate.NameTooLong
                        }
        , test "editing while submitting is ignored and a second submit sends nothing" <|
            \_ ->
                let
                    submitted : ApiKeyCreate.Model
                    submitted =
                        emptyModel
                            |> step (ApiKeyCreate.NameChanged "Build script")
                            |> step (ApiKeyCreate.ScopeChanged CreatableReadWrite)
                            |> step (ApiKeyCreate.ExpiryChanged ApiKeyCreate.NeverExpires)
                            |> step ApiKeyCreate.Submitted

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    edited : ApiKeyCreate.Model
                    edited =
                        submitted
                            |> step (ApiKeyCreate.NameChanged "Renamed")
                            |> step (ApiKeyCreate.ScopeChanged CreatableRead)
                            |> step (ApiKeyCreate.ExpiryChanged (ApiKeyCreate.ExpireInDays 30))
                            |> step ApiKeyCreate.ExpiryToggled

                    resubmitted : ApiKeyCreate.Model
                    resubmitted =
                        step ApiKeyCreate.Submitted edited
                in
                { form = formSummary edited
                , requestId = pendingRequestId edited
                , resubmitted = out ApiKeyCreate.Submitted edited
                , resubmittedRequestId = pendingRequestId resubmitted
                }
                    |> Expect.equal
                        { form =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiry = ApiKeyCreate.NeverExpires
                                , state = "submitting"
                                }
                        , requestId = Just requestId
                        , resubmitted = ApiKeyCreate.NoOp
                        , resubmittedRequestId = Just requestId
                        }
        , test "stale or duplicate create completions cannot replace the created key" <|
            \_ ->
                let
                    submitted : ApiKeyCreate.Model
                    submitted =
                        startCreate "Build script"

                    requestId : Int
                    requestId =
                        pendingRequestId submitted |> Maybe.withDefault 0

                    created : ApiKeyCreate.Model
                    created =
                        step (ApiKeyCreate.CreateCompleted requestId (Ok createdKey)) submitted

                    duplicate : ApiKeyCreate.Model
                    duplicate =
                        step
                            (ApiKeyCreate.CreateCompleted requestId (Ok otherCreatedKey))
                            created

                    wrongPending : ApiKeyCreate.Model
                    wrongPending =
                        step
                            (ApiKeyCreate.CreateCompleted (requestId + 1) (Ok otherCreatedKey))
                            submitted
                in
                { duplicateToken = createdToken duplicate
                , duplicatePhase = phase duplicate
                , wrongToken = createdToken wrongPending
                , wrongState = formSummary wrongPending
                }
                    |> Expect.equal
                        { duplicateToken = Just "token-once"
                        , duplicatePhase = "created"
                        , wrongToken = Nothing
                        , wrongState =
                            Just
                                { name = "Build script"
                                , scope = CreatableRead
                                , expiry = ApiKeyCreate.ExpireInDays 90
                                , state = "submitting"
                                }
                        }
        , test "a delayed copy result cannot affect a later copy" <|
            \_ ->
                let
                    created : ApiKeyCreate.Model
                    created =
                        makeCreated "Build script"

                    firstCopy : ApiKeyCreate.Model
                    firstCopy =
                        step ApiKeyCreate.CopyClicked created

                    firstCopyId : Int
                    firstCopyId =
                        copyPendingId firstCopy |> Maybe.withDefault 0

                    firstCopyDone : ApiKeyCreate.Model
                    firstCopyDone =
                        step (ApiKeyCreate.CopyCompleted firstCopyId True) firstCopy

                    secondCopy : ApiKeyCreate.Model
                    secondCopy =
                        step ApiKeyCreate.CopyClicked firstCopyDone

                    secondCopyId : Int
                    secondCopyId =
                        copyPendingId secondCopy |> Maybe.withDefault 0

                    staleResult : ApiKeyCreate.Model
                    staleResult =
                        step (ApiKeyCreate.CopyCompleted firstCopyId False) secondCopy

                    newResult : ApiKeyCreate.Model
                    newResult =
                        step (ApiKeyCreate.CopyCompleted secondCopyId True) staleResult
                in
                { idsDiffer = firstCopyId /= secondCopyId
                , staleState = copyStateName staleResult
                , newState = copyStateName newResult
                }
                    |> Expect.equal
                        { idsDiffer = True
                        , staleState = "pending"
                        , newState = "succeeded"
                        }
        ]



-- PROJECTION HELPERS


phase : ApiKeyCreate.Model -> String
phase model =
    case model of
        ApiKeyCreate.Form _ ->
            "form"

        ApiKeyCreate.Created _ ->
            "created"


form : ApiKeyCreate.Model -> Maybe ApiKeyCreate.CreateForm
form model =
    case model of
        ApiKeyCreate.Form formModel ->
            Just formModel.form

        ApiKeyCreate.Created _ ->
            Nothing


type alias FormSummary =
    { name : String
    , scope : CreatableScope
    , expiry : ApiKeyCreate.ExpiryChoice
    , state : String
    }


formSummary : ApiKeyCreate.Model -> Maybe FormSummary
formSummary model =
    form model
        |> Maybe.map
            (\createForm ->
                { name = createForm.name
                , scope = createForm.scope
                , expiry = createForm.expiry
                , state = createStateName createForm.state
                }
            )


createStateName : ApiKeyCreate.CreateState -> String
createStateName state =
    case state of
        ApiKeyCreate.Editing ->
            "editing"

        ApiKeyCreate.Invalid _ ->
            "invalid"

        ApiKeyCreate.Submitting _ ->
            "submitting"

        ApiKeyCreate.Failed _ ->
            "failed"


failedMessage : ApiKeyCreate.Model -> Maybe String
failedMessage model =
    form model
        |> Maybe.andThen
            (\createForm ->
                case createForm.state of
                    ApiKeyCreate.Failed message ->
                        Just message

                    _ ->
                        Nothing
            )


validationError : ApiKeyCreate.Model -> Maybe ApiKeyCreate.CreateError
validationError model =
    form model
        |> Maybe.andThen
            (\createForm ->
                case createForm.state of
                    ApiKeyCreate.Invalid error ->
                        Just error

                    _ ->
                        Nothing
            )


pendingRequestId : ApiKeyCreate.Model -> Maybe Int
pendingRequestId model =
    form model
        |> Maybe.andThen
            (\createForm ->
                case createForm.state of
                    ApiKeyCreate.Submitting requestId ->
                        Just requestId

                    _ ->
                        Nothing
            )


requestSummary :
    ApiKeyCreate.OutMsg
    -> Maybe { name : String, scope : CreatableScope, expiresInDays : Maybe Int }
requestSummary outMsg =
    case outMsg of
        ApiKeyCreate.RequestCreate _ request ->
            Just request

        _ ->
            Nothing


copySummary : ApiKeyCreate.OutMsg -> Maybe ( Int, String )
copySummary outMsg =
    case outMsg of
        ApiKeyCreate.CopyText copyId token ->
            Just ( copyId, token )

        _ ->
            Nothing


createdModel : ApiKeyCreate.Model -> Maybe ApiKeyCreate.CreatedModel
createdModel model =
    case model of
        ApiKeyCreate.Created value ->
            Just value

        ApiKeyCreate.Form _ ->
            Nothing


createdToken : ApiKeyCreate.Model -> Maybe String
createdToken model =
    createdModel model |> Maybe.map (.created >> .token)


copyPendingId : ApiKeyCreate.Model -> Maybe Int
copyPendingId model =
    createdModel model
        |> Maybe.andThen
            (\value ->
                case value.copyState of
                    ApiKeyCreate.CopyPending copyId ->
                        Just copyId

                    _ ->
                        Nothing
            )


copyStateName : ApiKeyCreate.Model -> String
copyStateName model =
    createdModel model
        |> Maybe.map
            (\value ->
                case value.copyState of
                    ApiKeyCreate.CopyIdle ->
                        "idle"

                    ApiKeyCreate.CopyPending _ ->
                        "pending"

                    ApiKeyCreate.CopySucceeded ->
                        "succeeded"

                    ApiKeyCreate.CopyFailed ->
                        "failed"
            )
        |> Maybe.withDefault "none"


emptyModel : ApiKeyCreate.Model
emptyModel =
    Tuple.first ApiKeyCreate.init


startCreate : String -> ApiKeyCreate.Model
startCreate name =
    emptyModel
        |> step (ApiKeyCreate.NameChanged name)
        |> step ApiKeyCreate.Submitted


makeCreated : String -> ApiKeyCreate.Model
makeCreated name =
    let
        submitted : ApiKeyCreate.Model
        submitted =
            startCreate name

        requestId : Int
        requestId =
            pendingRequestId submitted |> Maybe.withDefault 0
    in
    step (ApiKeyCreate.CreateCompleted requestId (Ok createdKey)) submitted


step : ApiKeyCreate.Msg -> ApiKeyCreate.Model -> ApiKeyCreate.Model
step msg model =
    first (ApiKeyCreate.update msg model)


out : ApiKeyCreate.Msg -> ApiKeyCreate.Model -> ApiKeyCreate.OutMsg
out msg model =
    third (ApiKeyCreate.update msg model)


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
