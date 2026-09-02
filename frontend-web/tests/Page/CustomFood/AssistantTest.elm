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
        , test "unauthorized draft failure expires the session" <|
            \_ ->
                enabled
                    |> Assistant.update
                        (Assistant.DraftCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                    |> third
                    |> Expect.equal Assistant.SessionExpired
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
