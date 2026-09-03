module Page.CustomFood.AssistantTest exposing (tests)

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant exposing (ConversationTurn, FoodDraftTurn(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
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
                    (Assistant.StatusLoaded (Ok { enabled = False }))
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
                            , ( "Serving size", "300 g" )
                            , ( "Default quantity", "1 bowl" )
                            ]
                        , nutrients = [ ( "Energy", "120.5 kcal" ) ]
                        , servings = [ ( "one bowl", "1 bowl = 300 g" ) ]
                        }
        , test "new session clears transient assistant state" <|
            \_ ->
                sent
                    |> Assistant.update (Assistant.DraftCompleted (Ok readyTurn))
                    |> first
                    |> Assistant.update (Assistant.DescriptionChanged "another answer")
                    |> first
                    |> Assistant.update (Assistant.ApplyDraftClicked True)
                    |> first
                    |> Assistant.update Assistant.NewSessionClicked
                    |> first
                    |> chatState
                    |> Expect.equal
                        (Just
                            { expanded = False
                            , transcript = []
                            , description = ""
                            , request = Assistant.Ready
                            , draft = Nothing
                            , warnings = []
                            , awaitingOverwriteConfirmation = False
                            }
                        )
        , test "new session recovers after reaching the 20-turn cap" <|
            \_ ->
                fullChat
                    |> Assistant.update (Assistant.DescriptionChanged "one more")
                    |> first
                    |> Assistant.update Assistant.SendClicked
                    |> first
                    |> Assistant.update Assistant.NewSessionClicked
                    |> first
                    |> requestState
                    |> Expect.equal (Just Assistant.Ready)
        , test "expanded assistant renders a new session action" <|
            \_ ->
                expanded
                    |> Assistant.view
                        Theme.light
                        { class = Phone, orientation = Portrait }
                        False
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "New session" ]
        ]


enabled : Assistant.Model
enabled =
    Assistant.update
        (Assistant.StatusLoaded (Ok { enabled = True }))
        (Tuple.first Assistant.init)
        |> first


sent : Assistant.Model
sent =
    enabled
        |> Assistant.update (Assistant.DescriptionChanged "one bowl of dal")
        |> first
        |> Assistant.update Assistant.SendClicked
        |> first


expanded : Assistant.Model
expanded =
    enabled
        |> Assistant.update Assistant.ToggleExpanded
        |> first


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
    , servingSizeG = Just "300"
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
        Assistant.RequestDraft conversation ->
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
