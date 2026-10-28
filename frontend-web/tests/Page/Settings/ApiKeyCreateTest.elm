module Page.Settings.ApiKeyCreateTest exposing (tests)

import Api.Client as Client
import Data.ApiKey exposing (ApiKey, ApiKeyScope(..), CreatableScope(..), CreatedApiKey)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeyCreateJourney
    exposing
        ( Journey
        , completeCopy
        , completeCreate
        , completePreviousCopy
        , completePreviousCreate
        , createdFeedback
        , createdToken
        , formError
        , send
        , staleSubmitDisabled
        , start
        , startCopy
        , submit
        , validationError
        )
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Settings.ApiKeyCreate"
        [ test "blank name, failed create, stale create, then a retried 401" <|
            \_ ->
                let
                    invalid : Journey
                    invalid =
                        start ApiKeyCreate.init
                            |> send ApiKeyCreate.Submitted

                    named : Journey
                    named =
                        start ApiKeyCreate.init
                            |> send (ApiKeyCreate.NameChanged "  Build script  ")
                            |> send (ApiKeyCreate.ScopeChanged CreatableReadWrite)
                            |> send (ApiKeyCreate.ExpiryChanged ApiKeyCreate.NeverExpires)

                    submitted : Journey
                    submitted =
                        submit named

                    failed : Journey
                    failed =
                        completeCreate (Err Client.NetworkError) submitted

                    retried : Journey
                    retried =
                        submit failed

                    afterStale : Journey
                    afterStale =
                        completePreviousCreate (Ok createdFirst) retried

                    afterUnauthorized : Journey
                    afterUnauthorized =
                        completeCreate (Err Fixtures.unauthorized) retried
                in
                { invalidError = formError invalid.model
                , request = Maybe.map .request submitted.create
                , failedError = formError failed.model
                , retryRequest = Maybe.map .request retried.create
                , stale =
                    ( staleSubmitDisabled afterStale.model
                    , formError afterStale.model
                    )
                , finalOut = afterUnauthorized.lastOut
                , finalError = formError afterUnauthorized.model
                , failure = afterUnauthorized.failure
                }
                    |> Expect.equal
                        { invalidError = Just nameRequired
                        , request =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiresInDays = Nothing
                                }
                        , failedError = Just Fixtures.networkErrorMessage
                        , retryRequest =
                            Just
                                { name = "Build script"
                                , scope = CreatableReadWrite
                                , expiresInDays = Nothing
                                }
                        , stale = ( Just True, Nothing )
                        , finalOut = ApiKeyCreate.SessionExpired
                        , finalError = Just unauthorizedMessage
                        , failure = Nothing
                        }
        , test "a created key ignores done and stale completions while copying" <|
            \_ ->
                let
                    created : Journey
                    created =
                        start ApiKeyCreate.init
                            |> send (ApiKeyCreate.NameChanged "Build script")
                            |> submit
                            |> completeCreate (Ok createdBuild)

                    copying : Journey
                    copying =
                        startCopy created

                    copyFailed : Journey
                    copyFailed =
                        completeCopy False copying

                    copyingAgain : Journey
                    copyingAgain =
                        startCopy copyFailed

                    afterStale : Journey
                    afterStale =
                        completePreviousCopy True copyingAgain

                    copied : Journey
                    copied =
                        completeCopy True copyingAgain

                    doneWhileCopying : Journey
                    doneWhileCopying =
                        send ApiKeyCreate.DoneClicked copying

                    done : Journey
                    done =
                        send ApiKeyCreate.DoneClicked copied
                in
                { copyPayload = Maybe.map .token copying.copy
                , doneWhileCopying = doneWhileCopying.lastOut
                , doneWhileCopyingFeedback = createdFeedback doneWhileCopying.model
                , failedFeedback = createdFeedback copyFailed.model
                , staleFeedback = createdFeedback afterStale.model
                , copiedFeedback = createdFeedback copied.model
                , finalOut = done.lastOut
                , failure = done.failure
                }
                    |> Expect.equal
                        { copyPayload = Just "token-build"
                        , doneWhileCopying = ApiKeyCreate.NoOp
                        , doneWhileCopyingFeedback = Just copyingLabel
                        , failedFeedback = Just copyFailedLabel
                        , staleFeedback = Just copyingLabel
                        , copiedFeedback = Just copiedLabel
                        , finalOut = ApiKeyCreate.Navigate SettingsApiKeys
                        , failure = Nothing
                        }
        , test "name validation matches Rust code-point rules" <|
            \_ ->
                let
                    -- Allowed exception: validation parity with Rust
                    -- `ApiKeyName::new`, whose trimming is code-point based.
                    validationCases : List ( String, String )
                    validationCases =
                        [ ( "", nameRequired )
                        , ( String.repeat 65 "😀", nameTooLong )
                        , ( "\u{200C}\u{200D}", nameInvalid )
                        , ( "bad\u{202E}name", nameInvalid )
                        , ( "bad\nname", nameInvalid )
                        , ( "Build\u{FEFF}", nameInvalid )
                        ]

                    trimmed : Journey
                    trimmed =
                        start ApiKeyCreate.init
                            |> send (ApiKeyCreate.NameChanged "\u{0085}Build\u{0085}")
                            |> submit

                    created : Journey
                    created =
                        completeCreate (Ok createdTrimmed) trimmed
                in
                { errors = List.map (Tuple.first >> validationError) validationCases
                , request = Maybe.map .request trimmed.create
                , finalOut = created.lastOut
                , token = createdToken created.model
                , failure = created.failure
                }
                    |> Expect.equal
                        { errors = List.map (Tuple.second >> Just) validationCases
                        , request =
                            Just
                                { name = "Build"
                                , scope = CreatableRead
                                , expiresInDays = Just 90
                                }
                        , finalOut = ApiKeyCreate.NoOp
                        , token = Just "token-trimmed"
                        , failure = Nothing
                        }
        ]



-- FIXTURES


createdFirst : CreatedApiKey
createdFirst =
    createdKey "key-4" "Stale script" "calco_pat_stale" "token-stale" Read


createdBuild : CreatedApiKey
createdBuild =
    createdKey "key-3" "Build script" "calco_pat_build" "token-build" ReadWrite


createdTrimmed : CreatedApiKey
createdTrimmed =
    createdKey "key-5" "Build" "calco_pat_trimmed" "token-trimmed" Read


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


nameRequired : String
nameRequired =
    I18n.en TidApiKeysNameRequired


nameInvalid : String
nameInvalid =
    I18n.en TidApiKeysNameInvalid


nameTooLong : String
nameTooLong =
    I18n.en TidApiKeysNameTooLong


copyingLabel : String
copyingLabel =
    I18n.en TidApiKeysCopying


copiedLabel : String
copiedLabel =
    I18n.en TidApiKeysCopied


copyFailedLabel : String
copyFailedLabel =
    I18n.en TidApiKeysCopyFailed


unauthorizedMessage : String
unauthorizedMessage =
    "Sign in again"
