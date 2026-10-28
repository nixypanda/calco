module Page.ApiKeyPaneTest exposing (tests)

{-| Page-level api-key pane generation is the one allowed generation-race
exception. A completion from a pane the user has already left must not mutate
the pane they re-entered. Generations and request/copy IDs are read only to
address simulated server responses; the assertions are on visible list, form,
token, and copy feedback.
-}

import Data.ApiKey exposing (ApiKey, ApiKeyScope(..), CreatedApiKey)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Page
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeyPaneJourney as PaneJourney exposing (Journey)
import Page.Settings.ApiKeyProjection as Projection
import Page.Settings.ApiKeys as ApiKeys
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page api key pane lifetimes"
        [ test "loading, creating, and returning shows the new key without a create pane" <|
            \_ ->
                let
                    createOpen : Journey
                    createOpen =
                        PaneJourney.start (Page.init ctx |> Fixtures.tupleFirst)
                            |> PaneJourney.keysLoaded [ keyA ]
                            |> PaneJourney.sendKeys ApiKeys.CreateClicked
                            |> PaneJourney.apply SettingsApiKeyCreate

                    submitting : Journey
                    submitting =
                        createOpen
                            |> PaneJourney.sendCreate
                                (ApiKeyCreate.NameChanged "Build script")
                            |> PaneJourney.submitCreate

                    created : Journey
                    created =
                        PaneJourney.completeCreate (Ok createdBuild) submitting

                    done : Journey
                    done =
                        PaneJourney.sendCreate ApiKeyCreate.DoneClicked created

                    refreshed : Journey
                    refreshed =
                        done
                            |> PaneJourney.apply SettingsApiKeys
                            |> PaneJourney.keysLoaded [ keyA, createdBuild.apiKey ]
                in
                { createOut = createOpen.lastOut
                , submitting = PaneJourney.createScreenOf submitting.model
                , created = PaneJourney.createScreenOf created.model
                , doneOut = done.lastOut
                , names = (PaneJourney.apiKeysScreenOf refreshed.model).names
                , createAfterBack = PaneJourney.createScreenOf refreshed.model
                , finalOut = refreshed.lastOut
                , failure = refreshed.failure
                }
                    |> Expect.equal
                        { createOut = Page.Navigate SettingsApiKeyCreate
                        , submitting = formScreen "Build script" creatingLabel True
                        , created = createdScreen "token-build" Nothing False
                        , doneOut = Page.Navigate SettingsApiKeys
                        , names = [ "First script", "Build script" ]
                        , createAfterBack = absentCreateScreen
                        , finalOut = Page.NoOutMsg
                        , failure = Nothing
                        }
        , test "stale pane completions do not change the re-entered panes" <|
            \_ ->
                let
                    afterStaleList : Journey
                    afterStaleList =
                        PaneJourney.start (Page.init ctx |> Fixtures.tupleFirst)
                            |> PaneJourney.keysLoaded [ keyA ]
                            |> PaneJourney.apply DiarySettings
                            |> PaneJourney.apply SettingsApiKeys
                            |> PaneJourney.keysLoaded [ keyB ]
                            |> PaneJourney.staleOldList [ keyA ]

                    createdOld : Journey
                    createdOld =
                        afterStaleList
                            |> PaneJourney.sendKeys ApiKeys.CreateClicked
                            |> PaneJourney.apply SettingsApiKeyCreate
                            |> PaneJourney.sendCreate
                                (ApiKeyCreate.NameChanged "First script")
                            |> PaneJourney.submitCreate
                            |> PaneJourney.completeCreate (Ok createdFirst)

                    copiedOld : Journey
                    copiedOld =
                        PaneJourney.startCopy createdOld

                    submittedNew : Journey
                    submittedNew =
                        copiedOld
                            |> PaneJourney.apply DiarySettings
                            |> PaneJourney.apply SettingsApiKeyCreate
                            |> PaneJourney.sendCreate
                                (ApiKeyCreate.NameChanged "Second script")
                            |> PaneJourney.submitCreate

                    afterStaleCreate : Journey
                    afterStaleCreate =
                        PaneJourney.completePreviousCreate
                            (Ok createdFirst)
                            submittedNew

                    createdNew : Journey
                    createdNew =
                        PaneJourney.completeCreate (Ok createdSecond) afterStaleCreate

                    copiedNew : Journey
                    copiedNew =
                        PaneJourney.startCopy createdNew

                    afterStaleCopy : Journey
                    afterStaleCopy =
                        PaneJourney.completePreviousCopy True copiedNew

                    afterNewCopyFailed : Journey
                    afterNewCopyFailed =
                        PaneJourney.completeCurrentCopy False afterStaleCopy

                    afterReturn : Journey
                    afterReturn =
                        afterNewCopyFailed
                            |> PaneJourney.sendCreate ApiKeyCreate.DoneClicked
                            |> PaneJourney.apply SettingsApiKeys
                in
                { staleList = (PaneJourney.apiKeysScreenOf afterStaleList.model).names
                , staleCreate = PaneJourney.createScreenOf afterStaleCreate.model
                , staleCopy = PaneJourney.createScreenOf afterStaleCopy.model
                , afterNewCopyFailed =
                    PaneJourney.createScreenOf afterNewCopyFailed.model
                , copyPayload = Maybe.map .token copiedNew.copy
                , createAfterBack = PaneJourney.createScreenOf afterReturn.model
                , finalOut = afterReturn.lastOut
                , failure = afterReturn.failure
                }
                    |> Expect.equal
                        { staleList = [ "Second script" ]
                        , staleCreate = formScreen "Second script" creatingLabel True
                        , staleCopy =
                            createdScreen "token-second" (Just copyingLabel) True
                        , afterNewCopyFailed =
                            createdScreen "token-second" (Just copyFailedLabel) False
                        , copyPayload = Just "token-second"
                        , createAfterBack = absentCreateScreen
                        , finalOut = Page.Navigate SettingsApiKeys
                        , failure = Nothing
                        }
        ]



-- EXPECTED SCREENS


absentCreateScreen : Projection.CreateScreen
absentCreateScreen =
    { form = Nothing, created = Nothing }


formScreen : String -> String -> Bool -> Projection.CreateScreen
formScreen name label disabled =
    { form =
        Just
            { name = name
            , submitLabel = label
            , submitDisabled = disabled
            , error = Nothing
            }
    , created = Nothing
    }


createdScreen : String -> Maybe String -> Bool -> Projection.CreateScreen
createdScreen token feedback copyDisabled =
    { form = Nothing
    , created =
        Just
            { token = token
            , copyFeedback = feedback
            , copyDisabled = copyDisabled
            , doneDisabled = copyDisabled
            }
    }



-- FIXTURES


ctx : Page.InitCtx
ctx =
    { route = SettingsApiKeys, today = Just Fixtures.today }


keyA : ApiKey
keyA =
    { id = "key-a"
    , name = "First script"
    , tokenHint = "calco_pat_aaaaaaaa"
    , scope = Read
    , createdAt = "2026-07-29T10:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Nothing
    }


keyB : ApiKey
keyB =
    { id = "key-b"
    , name = "Second script"
    , tokenHint = "calco_pat_bbbbbbbb"
    , scope = ReadWrite
    , createdAt = "2026-07-29T11:00:00Z"
    , lastUsedAt = Nothing
    , expiresAt = Nothing
    }


createdFirst : CreatedApiKey
createdFirst =
    { apiKey = keyA, token = "token-first" }


createdBuild : CreatedApiKey
createdBuild =
    { apiKey = { keyB | name = "Build script" }, token = "token-build" }


createdSecond : CreatedApiKey
createdSecond =
    { apiKey = keyB, token = "token-second" }


copyingLabel : String
copyingLabel =
    I18n.en TidApiKeysCopying


creatingLabel : String
creatingLabel =
    I18n.en TidCommonCreating


copyFailedLabel : String
copyFailedLabel =
    I18n.en TidApiKeysCopyFailed
