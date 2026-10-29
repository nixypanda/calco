module Api.FoodAssistant exposing (getStatus, requestDraft)

import Api.Client as Client
import Data.FoodAssistant as FoodAssistant
import File exposing (File)
import Http
import Json.Encode as Encode
import Url.Builder as Builder


getStatus : (Result Client.ApiError FoodAssistant.AssistantStatus -> msg) -> Cmd msg
getStatus toMsg =
    Client.get (Builder.absolute [ "api", "ai", "food-assistant", "status" ] [])
        FoodAssistant.assistantStatusDecoder
        toMsg


requestDraft :
    FoodAssistant.FoodDraftPurpose
    -> FoodAssistant.Conversation
    -> List File
    -> (Result Client.ApiError FoodAssistant.FoodDraftTurn -> msg)
    -> Cmd msg
requestDraft purpose conversation photos toMsg =
    Client.postMultipart (Builder.absolute [ "api", "ai", "custom-food", "draft" ] [])
        (Http.stringPart "conversation"
            (Encode.encode 0 (FoodAssistant.conversationEncoderFor purpose conversation))
            :: List.map (Http.filePart "photos") photos
        )
        (FoodAssistant.foodDraftTurnDecoder purpose)
        toMsg
