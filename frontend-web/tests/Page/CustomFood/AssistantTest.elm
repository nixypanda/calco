module Page.CustomFood.AssistantTest exposing (tests)

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant exposing (DraftStatus(..))
import Expect
import Page.CustomFood.Assistant as Assistant
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Assistant"
        [ test "disabled status does not expose a chat model" <|
            \_ ->
                Assistant.update
                    (Assistant.StatusLoaded (Ok { enabled = False, supportsImages = False }))
                    (Tuple.first Assistant.init)
                    |> first
                    |> Expect.equal Assistant.Disabled
        , test "enabled status starts collapsed" <|
            \_ ->
                Assistant.update
                    (Assistant.StatusLoaded (Ok { enabled = True, supportsImages = False }))
                    (Tuple.first Assistant.init)
                    |> first
                    |> Expect.equal
                        (Assistant.Enabled
                            { expanded = False
                            , transcript = []
                            , description = ""
                            , request = Assistant.Ready
                            , draft = Nothing
                            , warnings = []
                            , awaitingReplacementConfirmation = False
                            , supportsImages = False
                            , photos = []
                            , photoUrls = []
                            , photoError = Nothing
                            }
                        )
        , test "sending adds one user turn and requests multipart conversation" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DescriptionChanged "One bowl of biryani")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> third
                    |> Expect.equal
                        (Assistant.RequestDraft
                            expectedConversation
                            []
                        )
        , test "a retryable failure keeps the transcript and retry requests it again" <|
            \_ ->
                let
                    failed : Assistant.Model
                    failed =
                        enabled
                            |> Assistant.update (Assistant.DescriptionChanged "One bowl of biryani")
                            |> first
                            |> Assistant.update Assistant.SendClicked
                            |> first
                            |> Assistant.update (Assistant.DraftCompleted (Err Client.NetworkError))
                            |> first
                in
                failed
                    |> Assistant.update Assistant.RetryClicked
                    |> third
                    |> Expect.equal
                        (Assistant.RequestDraft
                            expectedConversation
                            []
                        )
        , test "manual values require confirmation before a draft can apply" <|
            \_ ->
                let
                    ready : Assistant.Model
                    ready =
                        enabled
                            |> Assistant.update (Assistant.DraftCompleted (Ok draftTurn))
                            |> first

                    awaitingConfirmation : Assistant.Model
                    awaitingConfirmation =
                        ready
                            |> Assistant.update (Assistant.ApplyDraftClicked True)
                            |> first
                in
                ( ready
                    |> Assistant.update (Assistant.ApplyDraftClicked True)
                    |> third
                , awaitingConfirmation
                    |> Assistant.update Assistant.ConfirmReplacementClicked
                    |> third
                )
                    |> Expect.equal
                        ( Assistant.NoOutMsg, Assistant.ApplyDraft draft )
        , test "draft preview exposes every field before application" <|
            \_ ->
                Assistant.draftPreviewData
                    { draft
                        | brand = Just "Restaurant"
                        , categories = [ "chicken", "rice", "main dish" ]
                        , nutrients =
                            [ { code = "ENERGY_KCAL", amountPer100g = 220 }
                            , { code = "FAT_G", amountPer100g = 15 }
                            , { code = "SODIUM_MG", amountPer100g = 500 }
                            ]
                        , servings =
                            [ { label = "One Bowl"
                              , quantity = 1
                              , unit = "serving"
                              , grams = 350
                              }
                            ]
                    }
                    |> Expect.equal
                        { details =
                            [ ( "Name", "Chicken biryani" )
                            , ( "Brand", "Restaurant" )
                            , ( "Categories", "chicken, rice, main dish" )
                            , ( "Serving size", "350 g" )
                            , ( "Default quantity", "1 serving" )
                            ]
                        , nutrients =
                            [ ( "Energy", "220 kcal" )
                            , ( "Fat", "15 g" )
                            , ( "Sodium", "500 mg" )
                            ]
                        , servings = [ ( "One Bowl", "1 serving = 350 g" ) ]
                        }
        , test "unauthorized draft failure expires the session" <|
            \_ ->
                enabled
                    |> Assistant.update
                        (Assistant.DraftCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                    |> third
                    |> Expect.equal Assistant.SessionExpired
        , test "photo metadata accepts supported images at or below 5 MiB" <|
            \_ ->
                Assistant.validatePhotoMetadata []
                    [ { mimeType = "image/jpeg", size = 5 * 1024 * 1024 }
                    , { mimeType = "image/png", size = 1 }
                    , { mimeType = "image/webp", size = 3 }
                    ]
                    |> Expect.equal (Ok ())
        , test "photo metadata rejects unsupported MIME types before upload" <|
            \_ ->
                Assistant.validatePhotoMetadata [] [ { mimeType = "image/gif", size = 1 } ]
                    |> Expect.equal (Err "Photos must be JPEG, PNG, or WebP.")
        , test "photo metadata rejects files above 5 MiB before upload" <|
            \_ ->
                Assistant.validatePhotoMetadata []
                    [ { mimeType = "image/png", size = 5 * 1024 * 1024 + 1 } ]
                    |> Expect.equal (Err "Each photo must be 5 MiB or smaller.")
        , test "photo metadata accepts exactly 12 MiB across existing and selected photos" <|
            \_ ->
                Assistant.validatePhotoMetadata
                    [ { mimeType = "image/jpeg", size = 5 * 1024 * 1024 }
                    , { mimeType = "image/png", size = 5 * 1024 * 1024 }
                    ]
                    [ { mimeType = "image/webp", size = 2 * 1024 * 1024 } ]
                    |> Expect.equal (Ok ())
        , test "photo metadata rejects more than 12 MiB across existing and selected photos" <|
            \_ ->
                Assistant.validatePhotoMetadata
                    [ { mimeType = "image/jpeg", size = 5 * 1024 * 1024 }
                    , { mimeType = "image/png", size = 5 * 1024 * 1024 }
                    ]
                    [ { mimeType = "image/webp", size = 2 * 1024 * 1024 + 1 } ]
                    |> Expect.equal (Err "Photos together must be 12 MiB or smaller.")
        , test "a ready draft clears stale photo preview state" <|
            \_ ->
                let
                    chat : Assistant.ChatModel
                    chat =
                        { expanded = False
                        , transcript = []
                        , description = ""
                        , request = Assistant.Sending
                        , draft = Nothing
                        , warnings = []
                        , awaitingReplacementConfirmation = False
                        , supportsImages = True
                        , photos = []
                        , photoUrls = [ Just "blob:stale-preview" ]
                        , photoError = Just "A stale photo error"
                        }
                in
                Assistant.update (Assistant.DraftCompleted (Ok draftTurn)) (Assistant.Enabled chat)
                    |> first
                    |> Expect.equal
                        (Assistant.Enabled
                            { chat
                                | request = Assistant.Ready
                                , draft = Just draft
                                , warnings = [ "Nutrition is estimated." ]
                                , transcript =
                                    [ { role = FoodAssistant.Assistant
                                      , text = "Here is an estimate."
                                      }
                                    ]
                                , photoUrls = []
                                , photoError = Nothing
                            }
                        )
        ]


enabled : Assistant.Model
enabled =
    Assistant.update
        (Assistant.StatusLoaded (Ok { enabled = True, supportsImages = False }))
        (Tuple.first Assistant.init)
        |> first


draftTurn : FoodAssistant.FoodDraftTurn
draftTurn =
    { assistantMessage = "Here is an estimate."
    , status = DraftReady
    , draft = Just draft
    , warnings = [ "Nutrition is estimated." ]
    }


draft : FoodAssistant.FoodDraft
draft =
    { name = "Chicken biryani"
    , brand = Nothing
    , categories = [ "rice dishes" ]
    , servingSizeG = Just 350
    , defaultQuantity = Just 1
    , defaultUnit = Just "serving"
    , nutrients = [ { code = "ENERGY_KCAL", amountPer100g = 172 } ]
    , servings = [ { label = "1 bowl", quantity = 1, unit = "serving", grams = 350 } ]
    }


expectedConversation : FoodAssistant.Conversation
expectedConversation =
    { turns = [ { role = FoodAssistant.User, text = "One bowl of biryani" } ] }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
