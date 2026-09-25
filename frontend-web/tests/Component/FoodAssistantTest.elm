module Component.FoodAssistantTest exposing (tests)

import Api.Client as Client
import Component.FoodAssistant as Assistant
import Data.FoodAssistant as FoodAssistant exposing (ConversationTurn, FoodDraftTurn(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Html.Attributes as HtmlAttributes
import Json.Encode as Encode
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.Env exposing (Env)
import Ui.Theme as Theme


viewEnv : Env
viewEnv =
    { theme = Theme.light
    , device = { class = Phone, orientation = Portrait }
    , language = Util.EN_US
    }


tests : Test
tests =
    describe "Component.FoodAssistant"
        [ test "status error can be retried" <|
            \_ ->
                Assistant.update
                    (Assistant.StatusLoaded (Err Client.NetworkError))
                    (Tuple.first Assistant.init)
                    |> first
                    |> Assistant.update Assistant.RetryStatusClicked
                    |> third
                    |> Expect.equal Assistant.RequestStatus
        , test "clarification and retry preserve the transcript and resend it" <|
            \_ ->
                let
                    followUp : Maybe String
                    followUp =
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

                    retry : Maybe String
                    retry =
                        sent
                            |> Assistant.update (Assistant.DraftCompleted (Err Client.NetworkError))
                            |> first
                            |> Assistant.update Assistant.RetryClicked
                            |> third
                            |> requestJson
                in
                ( followUp, retry )
                    |> Expect.equal
                        ( Just
                            (String.concat
                                [ "{\"purpose\":\"custom_food\",\"turns\":[{\"role\":\"user\","
                                , "\"text\":\"one bowl of dal\"},{\"role\":\"assistant\","
                                , "\"text\":\"How many grams?\"},{\"role\":\"user\","
                                , "\"text\":\"300 grams\"}]}"
                                ]
                            )
                        , Just
                            (String.concat
                                [ "{\"purpose\":\"custom_food\",\"turns\":["
                                , "{\"role\":\"user\",\"text\":\"one bowl of dal\"}]}"
                                ]
                            )
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
        , test "applying a ready draft respects manual-form confirmation" <|
            \_ ->
                let
                    ready : Assistant.Model
                    ready =
                        enabled
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> first

                    preview : Assistant.OutMsg
                    preview =
                        enabled
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> third

                    awaiting : Assistant.Model
                    awaiting =
                        ready |> Assistant.update (Assistant.ApplyDraftClicked True) |> first
                in
                { preview = preview
                , direct = ready |> Assistant.update (Assistant.ApplyDraftClicked False) |> third
                , cancelled = awaiting |> Assistant.update Assistant.CancelOverwriteClicked |> third
                , confirmed =
                    awaiting |> Assistant.update Assistant.ConfirmOverwriteClicked |> third
                }
                    |> Expect.equal
                        { preview = Assistant.NoOutMsg
                        , direct = Assistant.ApplyDraft draft
                        , cancelled = Assistant.NoOutMsg
                        , confirmed = Assistant.ApplyDraft draft
                        }
        , test "ad-hoc completion returns the draft and suggested portion to its parent" <|
            \_ ->
                let
                    suggestedLog : FoodAssistant.SuggestedLog
                    suggestedLog =
                        { amount = "1"
                        , unit = "bowl"
                        , totalWeightGrams = "300"
                        }

                    logTurn : FoodDraftTurn
                    logTurn =
                        DraftReady
                            { assistantMessage = "Review this estimate."
                            , draft = draft
                            , suggestedLog = Just suggestedLog
                            , warnings = [ "Estimated" ]
                            }
                in
                enabled
                    |> Assistant.updateFor FoodAssistant.AdHocLog
                        (Assistant.DraftCompleted (Ok logTurn))
                    |> first
                    |> Assistant.updateFor FoodAssistant.AdHocLog
                        (Assistant.ApplyDraftClicked False)
                    |> third
                    |> Expect.equal
                        (Assistant.CompleteDraft
                            { draft = draft
                            , suggestedLog = suggestedLog
                            , warnings = [ "Estimated" ]
                            }
                        )
        , test "asking for changes reveals the conversation and a revised draft hides it" <|
            \_ ->
                let
                    ready : Assistant.Model
                    ready =
                        enabled
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> first

                    asking : Assistant.Model
                    asking =
                        ready |> Assistant.update Assistant.AskForChangesClicked |> first

                    revised : Assistant.Model
                    revised =
                        asking
                            |> Assistant.update (Assistant.DescriptionChanged "Use 250 g")
                            |> first
                            |> Assistant.update Assistant.SendClicked
                            |> first
                            |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                            |> first
                in
                Expect.all
                    [ \_ ->
                        asking
                            |> Assistant.view viewEnv False
                            |> Element.layout []
                            |> Query.fromHtml
                            |> Query.has
                                [ Selector.text "Conversation"
                                , Selector.text "What should change?"
                                , Selector.text "Cancel changes"
                                , Selector.text "New session"
                                , Selector.text "Send"
                                ]
                    , \_ ->
                        revised
                            |> chatState
                            |> Maybe.map .askingForChanges
                            |> Expect.equal (Just False)
                    ]
                    ()
        , test "new session confirms before clearing and recovers from the turn cap" <|
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
                        existing |> Assistant.update Assistant.NewSessionClicked |> first

                    confirmed : Assistant.Model
                    confirmed =
                        awaiting |> Assistant.update Assistant.ConfirmNewSessionClicked |> first

                    recovered : Assistant.Model
                    recovered =
                        fullChat
                            |> Assistant.update (Assistant.DescriptionChanged "one more")
                            |> first
                            |> Assistant.update Assistant.SendClicked
                            |> first
                            |> Assistant.update Assistant.NewSessionClicked
                            |> first
                            |> Assistant.update Assistant.ConfirmNewSessionClicked
                            |> first
                in
                { awaitingConfirmation =
                    awaiting |> chatState |> Maybe.map .awaitingNewSessionConfirmation
                , cancelledTranscript =
                    awaiting
                        |> Assistant.update Assistant.CancelNewSessionClicked
                        |> first
                        |> chatState
                        |> Maybe.map .transcript
                , confirmed = confirmed |> chatState
                , recovered = recovered |> requestState
                }
                    |> Expect.equal
                        { awaitingConfirmation = Just True
                        , cancelledTranscript = existing |> chatState |> Maybe.map .transcript
                        , confirmed = Just emptyExpandedChat
                        , recovered = Just Assistant.Ready
                        }
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
        , test "image assistants expose a rear-camera input and file chooser" <|
            \_ ->
                imageEnabled
                    |> Assistant.view
                        viewEnv
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
        , test "photo metadata rejects unsupported, oversized, and over-limit selections" <|
            \_ ->
                { unsupported =
                    Assistant.validatePhotoMetadata []
                        [ { mimeType = "image/gif", size = 1 } ]
                , oversized =
                    Assistant.validatePhotoMetadata []
                        [ { mimeType = "image/png", size = 15 * 1024 * 1024 + 1 } ]
                , tooMany =
                    Assistant.validatePhotoMetadata
                        (List.repeat 4 { mimeType = "image/jpeg", size = 1 })
                        [ { mimeType = "image/png", size = 1 } ]
                , totalTooLarge =
                    Assistant.validatePhotoMetadata
                        [ { mimeType = "image/jpeg", size = 15 * 1024 * 1024 }
                        , { mimeType = "image/png", size = 15 * 1024 * 1024 }
                        ]
                        [ { mimeType = "image/webp", size = 10 * 1024 * 1024 + 1 } ]
                }
                    |> Expect.equal
                        { unsupported = Err "Photos must be JPEG, PNG, or WebP."
                        , oversized = Err "Each photo must be 15 MiB or smaller."
                        , tooMany = Err "Only four photos can be attached."
                        , totalTooLarge = Err "Photos together must be 40 MiB or smaller."
                        }
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
    , suggestedLog = Nothing
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
    , servings = [ { unit = "bowl", gramsPerUnit = "300" } ]
    }


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft = draft
        , suggestedLog = Nothing
        , warnings = []
        }


requestJson : Assistant.OutMsg -> Maybe String
requestJson outMsg =
    case outMsg of
        Assistant.RequestDraft _ conversation _ ->
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
