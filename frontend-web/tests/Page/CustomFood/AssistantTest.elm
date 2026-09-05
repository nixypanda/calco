module Page.CustomFood.AssistantTest exposing (tests)

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant exposing (ConversationTurn, FoodDraftTurn(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Html.Attributes as HtmlAttributes
import Json.Encode as Encode
import Page.CustomFood.Assistant as Assistant
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.CustomFood.Assistant"
        [ test "disabled status exposes no chat state" <|
            \_ ->
                Assistant.update
                    (Assistant.StatusLoaded
                        (Ok { enabled = False, supportsImages = False })
                    )
                    (Tuple.first Assistant.init)
                    |> first
                    |> Expect.equal Assistant.Disabled
        , test "status error can be retried" <|
            \_ ->
                Assistant.update
                    (Assistant.StatusLoaded (Err Client.NetworkError))
                    (Tuple.first Assistant.init)
                    |> first
                    |> Assistant.update Assistant.RetryStatusClicked
                    |> third
                    |> Expect.equal Assistant.RequestStatus
        , test "sending appends a user turn and requests a conversation" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DescriptionChanged "one bowl of dal")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> third
                    |> requestJson
                    |> Expect.equal
                        (Just
                            "{\"turns\":[{\"role\":\"user\",\"text\":\"one bowl of dal\"}]}"
                        )
        , test "clarification appends transcript and allows a follow-up" <|
            \_ ->
                sent
                    |> Assistant.update
                        (Assistant.DraftCompleted
                            (Ok
                                (NeedsClarification
                                    { assistantMessage = "How many grams?" }
                                )
                            )
                        )
                    |> first
                    |> Assistant.update (Assistant.DescriptionChanged "300 grams")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> third
                    |> requestJson
                    |> Expect.equal
                        (Just
                            (String.concat
                                [ "{\"turns\":[{\"role\":\"user\","
                                , "\"text\":\"one bowl of dal\"},{\"role\":\"assistant\","
                                , "\"text\":\"How many grams?\"},{\"role\":\"user\","
                                , "\"text\":\"300 grams\"}]}"
                                ]
                            )
                        )
        , test "retry keeps and resends the existing transcript" <|
            \_ ->
                sent
                    |> Assistant.update (Assistant.DraftCompleted (Err Client.NetworkError))
                    |> first
                    |> Assistant.update Assistant.RetryClicked
                    |> third
                    |> requestJson
                    |> Expect.equal
                        (Just
                            "{\"turns\":[{\"role\":\"user\",\"text\":\"one bowl of dal\"}]}"
                        )
        , test "rate limits expose a retryable friendly failure" <|
            \_ ->
                sent
                    |> Assistant.update
                        (Assistant.DraftCompleted (Err (Client.RateLimited (Just 12))))
                    |> first
                    |> requestState
                    |> Expect.equal
                        (Just
                            (Assistant.RequestFailed
                                "The assistant is busy. Try again in 12 seconds."
                            )
                        )
        , test "backend validation messages explain what must be corrected" <|
            \_ ->
                sent
                    |> Assistant.update
                        (Assistant.DraftCompleted
                            (Err
                                (Client.BadStatus
                                    400
                                    "photo_dimensions_too_large"
                                    "A photo has too many pixels."
                                )
                            )
                        )
                    |> first
                    |> requestState
                    |> Expect.equal
                        (Just
                            (Assistant.RequestFailed
                                "A photo has too many pixels."
                            )
                        )
        , test "ready result is previewed before any apply output" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> (\( model, _, outMsg ) ->
                            ( outMsg
                            , model
                                |> Assistant.update (Assistant.ApplyDraftClicked False)
                                |> third
                            )
                       )
                    |> Expect.equal
                        ( Assistant.NoOutMsg, Assistant.ApplyDraft draft )
        , test "ready draft hides the conversation behind ask for changes" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Draft preview"
                        , Selector.text "New session"
                        , Selector.text "Apply to form"
                        , Selector.text "Ask for changes"
                        ]
        , test "ready draft does not render conversation controls" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.hasNot
                        [ Selector.text "Conversation"
                        , Selector.text "Food description or answer"
                        , Selector.text "Send"
                        ]
        , test "ask for changes reveals the conversation and follow-up input" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.update Assistant.AskForChangesClicked
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Conversation"
                        , Selector.text "What should change?"
                        , Selector.text "Cancel changes"
                        , Selector.text "New session"
                        , Selector.text "Send"
                        ]
        , test "a revised draft hides the conversation again" <|
            \_ ->
                enabled
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.update Assistant.AskForChangesClicked
                    |> first
                    |> Assistant.update (Assistant.DescriptionChanged "Use 250 g")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> first
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> chatState
                    |> Maybe.map .askingForChanges
                    |> Expect.equal (Just False)
        , test "manual form requires confirmation and cancel does not apply" <|
            \_ ->
                let
                    awaiting : Assistant.Model
                    awaiting =
                        enabled
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> first
                            |> Assistant.update (Assistant.ApplyDraftClicked True)
                            |> first
                in
                ( awaiting |> Assistant.update Assistant.CancelOverwriteClicked |> third
                , awaiting |> Assistant.update Assistant.ConfirmOverwriteClicked |> third
                )
                    |> Expect.equal
                        ( Assistant.NoOutMsg, Assistant.ApplyDraft draft )
        , test "preview includes details nutrients and servings" <|
            \_ ->
                Assistant.draftPreviewData draft
                    |> Expect.equal
                        { details =
                            [ ( "Name", "Dal" )
                            , ( "Brand", "Not specified" )
                            , ( "Categories", "lentils" )
                            , ( "Default quantity", "1 bowl" )
                            ]
                        , nutrients = [ ( "Energy", "120.5 kcal" ) ]
                        , servings = [ ( "one bowl", "1 bowl = 300 g" ) ]
                        }
        , test "new session asks before clearing transient assistant state" <|
            \_ ->
                let
                    existing : Assistant.Model
                    existing =
                        sent
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> first
                            |> Assistant.update (Assistant.DescriptionChanged "another answer")
                            |> first

                    awaiting : Assistant.Model
                    awaiting =
                        existing
                            |> Assistant.update Assistant.NewSessionClicked
                            |> first
                in
                ( awaiting |> chatState |> Maybe.map .awaitingNewSessionConfirmation
                , awaiting
                    |> Assistant.update Assistant.CancelNewSessionClicked
                    |> first
                    |> chatState
                    |> Maybe.map .transcript
                , awaiting
                    |> Assistant.update Assistant.ConfirmNewSessionClicked
                    |> first
                    |> chatState
                )
                    |> Expect.equal
                        ( Just True
                        , existing |> chatState |> Maybe.map .transcript
                        , Just emptyExpandedChat
                        )
        , test "confirmed new session recovers after reaching the 20-turn cap" <|
            \_ ->
                fullChat
                    |> Assistant.update (Assistant.DescriptionChanged "one more")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> first
                    |> Assistant.update Assistant.NewSessionClicked
                    |> first
                    |> Assistant.update Assistant.ConfirmNewSessionClicked
                    |> first
                    |> requestState
                    |> Expect.equal (Just Assistant.Ready)
        , test "new session cannot reset an in-flight request" <|
            \_ ->
                sent
                    |> Assistant.update Assistant.NewSessionClicked
                    |> first
                    |> chatState
                    |> Maybe.map
                        (\chat ->
                            ( chat.request
                            , chat.transcript
                            , chat.awaitingNewSessionConfirmation
                            )
                        )
                    |> Expect.equal
                        (sent
                            |> chatState
                            |> Maybe.map
                                (\chat ->
                                    ( chat.request
                                    , chat.transcript
                                    , False
                                    )
                                )
                        )
        , test "assistant actions use their scoped labels" <|
            \_ ->
                sent
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "New session"
                        , Selector.text "Apply to form"
                        , Selector.text "Ask for changes"
                        ]
        , test "new session confirmation explains its scope" <|
            \_ ->
                sent
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.update Assistant.NewSessionClicked
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text
                            (String.concat
                                [ "Start a new session? The current conversation and draft "
                                , "will be discarded. Your food form will not be changed."
                                ]
                            )
                        , Selector.text "Cancel"
                        , Selector.text "Start new session"
                        ]
        , test "overwrite confirmation uses explicit draft actions" <|
            \_ ->
                sent
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.update (Assistant.ApplyDraftClicked True)
                    |> first
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        True
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Cancel"
                        , Selector.text "Replace form values"
                        ]
        , test "focused assistant exposes its input without a reveal action" <|
            \_ ->
                enabled
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Food description or answer"
                        , Selector.text "Send"
                        ]
        , test "text-only assistants hide all photo controls" <|
            \_ ->
                enabled
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.hasNot
                        [ Selector.text "Take photo"
                        , Selector.text "Choose photos"
                        ]
        , test "image assistants expose a rear-camera input and file chooser" <|
            \_ ->
                imageEnabled
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Take photo"
                        , Selector.text "Choose photos"
                        , Selector.attribute (HtmlAttributes.type_ "file")
                        , Selector.attribute (HtmlAttributes.accept "image/*")
                        , Selector.attribute
                            (HtmlAttributes.attribute "capture" "environment")
                        ]
        , test "photo metadata accepts supported files at the limits" <|
            \_ ->
                Assistant.validatePhotoMetadata
                    [ { mimeType = "image/jpeg", size = 15 * 1024 * 1024 }
                    , { mimeType = "image/png", size = 15 * 1024 * 1024 }
                    ]
                    [ { mimeType = "image/webp", size = 10 * 1024 * 1024 }
                    , { mimeType = "image/jpeg", size = 0 }
                    ]
                    |> Expect.equal (Ok ())
        , test "photo metadata rejects unsupported formats and oversized files" <|
            \_ ->
                ( Assistant.validatePhotoMetadata []
                    [ { mimeType = "image/gif", size = 1 } ]
                , Assistant.validatePhotoMetadata []
                    [ { mimeType = "image/png", size = 15 * 1024 * 1024 + 1 } ]
                )
                    |> Expect.equal
                        ( Err "Photos must be JPEG, PNG, or WebP."
                        , Err "Each photo must be 15 MiB or smaller."
                        )
        , test "photo metadata enforces four-photo and combined-size limits" <|
            \_ ->
                ( Assistant.validatePhotoMetadata
                    (List.repeat 4 { mimeType = "image/jpeg", size = 1 })
                    [ { mimeType = "image/png", size = 1 } ]
                , Assistant.validatePhotoMetadata
                    [ { mimeType = "image/jpeg", size = 15 * 1024 * 1024 }
                    , { mimeType = "image/png", size = 15 * 1024 * 1024 }
                    ]
                    [ { mimeType = "image/webp", size = 10 * 1024 * 1024 + 1 } ]
                )
                    |> Expect.equal
                        ( Err "Only four photos can be attached."
                        , Err "Photos together must be 40 MiB or smaller."
                        )
        , test "removing a photo keeps file and preview positions aligned" <|
            \_ ->
                ( Assistant.removeAt 1 [ "first", "second", "third" ]
                , Assistant.removeAt 1 [ "url-1", "url-2", "url-3" ]
                )
                    |> Expect.equal
                        ( [ "first", "third" ], [ "url-1", "url-3" ] )
        , test "clarification and failure retain photo previews for resend" <|
            \_ ->
                let
                    selected : Assistant.Model
                    selected =
                        withPreviewUrl "blob:food-photo" sent

                    clarified : Assistant.Model
                    clarified =
                        selected
                            |> Assistant.update
                                (Assistant.DraftCompleted
                                    (Ok
                                        (NeedsClarification
                                            { assistantMessage = "How much?" }
                                        )
                                    )
                                )
                            |> first

                    failed : Assistant.Model
                    failed =
                        selected
                            |> Assistant.update
                                (Assistant.DraftCompleted (Err Client.NetworkError))
                            |> first
                in
                ( Assistant.previewUrls clarified, Assistant.previewUrls failed )
                    |> Expect.equal
                        ( [ "blob:food-photo" ], [ "blob:food-photo" ] )
        , test "ready draft and confirmed new session clear and revoke previews" <|
            \_ ->
                let
                    selected : Assistant.Model
                    selected =
                        withPreviewUrl "blob:food-photo" sent

                    readyResult : ( Assistant.Model, Cmd Assistant.Msg, Assistant.OutMsg )
                    readyResult =
                        Assistant.update (Assistant.DraftCompleted (Ok readyTurn)) selected

                    sessionResult : ( Assistant.Model, Cmd Assistant.Msg, Assistant.OutMsg )
                    sessionResult =
                        selected
                            |> Assistant.update
                                (Assistant.DraftCompleted
                                    (Ok
                                        (NeedsClarification
                                            { assistantMessage = "How much?" }
                                        )
                                    )
                                )
                            |> first
                            |> Assistant.update Assistant.NewSessionClicked
                            |> first
                            |> Assistant.update Assistant.ConfirmNewSessionClicked
                in
                { readyUrls = readyResult |> first |> Assistant.previewUrls
                , readyOut = readyResult |> third
                , sessionUrls = sessionResult |> first |> Assistant.previewUrls
                , sessionOut = sessionResult |> third
                }
                    |> Expect.equal
                        { readyUrls = []
                        , readyOut =
                            Assistant.RevokePhotoPreviewUrls [ "blob:food-photo" ]
                        , sessionUrls = []
                        , sessionOut =
                            Assistant.RevokePhotoPreviewUrls [ "blob:food-photo" ]
                        }
        ]


enabled : Assistant.Model
enabled =
    Assistant.update
        (Assistant.StatusLoaded
            (Ok { enabled = True, supportsImages = False })
        )
        (Tuple.first Assistant.init)
        |> first


imageEnabled : Assistant.Model
imageEnabled =
    Assistant.update
        (Assistant.StatusLoaded
            (Ok { enabled = True, supportsImages = True })
        )
        (Tuple.first Assistant.init)
        |> first


withPreviewUrl : String -> Assistant.Model -> Assistant.Model
withPreviewUrl url model =
    case model of
        Assistant.Enabled chat ->
            Assistant.Enabled { chat | photoUrls = [ Just url ] }

        other ->
            other


sent : Assistant.Model
sent =
    enabled
        |> Assistant.update (Assistant.DescriptionChanged "one bowl of dal")
        |> first
        |> Assistant.update Assistant.SendClicked
        |> first


emptyExpandedChat : Assistant.ChatModel
emptyExpandedChat =
    { transcript = []
    , description = ""
    , request = Assistant.Ready
    , draft = Nothing
    , warnings = []
    , askingForChanges = False
    , awaitingOverwriteConfirmation = False
    , awaitingNewSessionConfirmation = False
    , supportsImages = False
    , photos = []
    , photoUrls = []
    , photoError = Nothing
    }


fullChat : Assistant.Model
fullChat =
    let
        turns : List ConversationTurn
        turns =
            List.range 1 10
                |> List.concatMap
                    (\index ->
                        [ FoodAssistant.userTurn ("food " ++ String.fromInt index)
                        , FoodAssistant.assistantTurn ("answer " ++ String.fromInt index)
                        ]
                    )
                |> List.filterMap Result.toMaybe
    in
    case enabled of
        Assistant.Enabled chat ->
            Assistant.Enabled { chat | transcript = turns }

        other ->
            other


draft : FoodAssistant.FoodDraft
draft =
    { name = "Dal"
    , brand = Nothing
    , categories = [ "lentils" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "bowl"
    , nutrients = [ { code = "ENERGY_KCAL", amountPer100g = "120.5" } ]
    , servings = [ { label = "one bowl", quantity = "1", unit = "bowl", grams = "300" } ]
    }


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft = draft
        , warnings = []
        }


requestJson : Assistant.OutMsg -> Maybe String
requestJson outMsg =
    case outMsg of
        Assistant.RequestDraft conversation _ ->
            Just (Encode.encode 0 (FoodAssistant.conversationEncoder conversation))

        _ ->
            Nothing


requestState : Assistant.Model -> Maybe Assistant.RequestState
requestState model =
    case model of
        Assistant.Enabled chat ->
            Just chat.request

        _ ->
            Nothing


chatState : Assistant.Model -> Maybe Assistant.ChatModel
chatState model =
    case model of
        Assistant.Enabled chat ->
            Just chat

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
