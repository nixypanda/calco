module Api.FoodAssistant exposing (getStatus, requestDraft)

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant exposing (AssistantStatus, Conversation, FoodDraftTurn)
import Http
import Json.Encode as Encode
import Url.Builder as Builder


getStatus : (Result Client.ApiError AssistantStatus -> msg) -> Cmd msg
getStatus toMsg =
    Client.get
        (Builder.absolute [ "api", "ai", "food-assistant", "status" ] [])
        FoodAssistant.assistantStatusDecoder
        toMsg


requestDraft : Conversation -> (Result Client.ApiError FoodDraftTurn -> msg) -> Cmd msg
requestDraft conversation toMsg =
    Client.postMultipart
        (Builder.absolute [ "api", "ai", "custom-food", "draft" ] [])
        [ Http.stringPart
            "conversation"
            (Encode.encode 0 (FoodAssistant.conversationEncoder conversation))
        ]
        FoodAssistant.foodDraftTurnDecoder
        toMsg
