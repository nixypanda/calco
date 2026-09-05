module Data.FoodAssistant exposing
    ( AssistantStatus
    , Conversation
    , ConversationRole(..)
    , ConversationTurn
    , DraftNutrient
    , DraftServing
    , FoodDraft
    , FoodDraftTurn(..)
    , assistantMessage
    , assistantStatusDecoder
    , assistantTurn
    , conversation
    , conversationEncoder
    , foodDraftTurnDecoder
    , turnRole
    , turnText
    , userTurn
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias AssistantStatus =
    { enabled : Bool
    , supportsImages : Bool
    }


type ConversationRole
    = User
    | Assistant


type ConversationTurn
    = ConversationTurn ConversationRole String


type Conversation
    = Conversation (List ConversationTurn)


type FoodDraftTurn
    = NeedsClarification { assistantMessage : String }
    | DraftReady
        { assistantMessage : String
        , draft : FoodDraft
        , warnings : List String
        }


type alias FoodDraft =
    { name : String
    , brand : Maybe String
    , categories : List String
    , servingSizeG : Maybe String
    , defaultQuantity : Maybe String
    , defaultUnit : Maybe String
    , nutrients : List DraftNutrient
    , servings : List DraftServing
    }


type alias DraftNutrient =
    { code : String
    , amountPer100g : String
    }


type alias DraftServing =
    { label : String
    , quantity : String
    , unit : String
    , grams : String
    }


assistantStatusDecoder : Decoder AssistantStatus
assistantStatusDecoder =
    strictObject [ "enabled", "supports_images" ] <|
        Decode.map2 AssistantStatus
            (Decode.field "enabled" Decode.bool)
            (Decode.field "supports_images" Decode.bool)


foodDraftTurnDecoder : Decoder FoodDraftTurn
foodDraftTurnDecoder =
    strictObject [ "assistant_message", "status", "draft", "warnings" ] <|
        (Decode.field "status" Decode.string
            |> Decode.andThen draftTurnForStatus
        )


draftTurnForStatus : String -> Decoder FoodDraftTurn
draftTurnForStatus status =
    case status of
        "needs_clarification" ->
            Decode.map3
                (\message draft warnings -> ( message, draft, warnings ))
                (Decode.field "assistant_message" Decode.string)
                (Decode.field "draft" (Decode.nullable foodDraftDecoder))
                (Decode.field "warnings" (Decode.list Decode.string))
                |> Decode.andThen
                    (\( message, draft, warnings ) ->
                        if draft == Nothing && List.isEmpty warnings then
                            Decode.succeed (NeedsClarification { assistantMessage = message })

                        else
                            Decode.fail "A clarification cannot contain a draft or warnings"
                    )

        "draft_ready" ->
            Decode.map3
                (\message draft warnings ->
                    DraftReady
                        { assistantMessage = message
                        , draft = draft
                        , warnings = warnings
                        }
                )
                (Decode.field "assistant_message" Decode.string)
                (Decode.field "draft" foodDraftDecoder)
                (Decode.field "warnings" (Decode.list Decode.string))

        _ ->
            Decode.fail "Unsupported food-assistant draft status"


foodDraftDecoder : Decoder FoodDraft
foodDraftDecoder =
    strictObject
        [ "name"
        , "brand"
        , "categories"
        , "serving_size_g"
        , "default_quantity"
        , "default_unit"
        , "nutrients"
        , "servings"
        ]
    <|
        Decode.map8 FoodDraft
            (Decode.field "name" Decode.string)
            (Decode.field "brand" (Decode.nullable Decode.string))
            (Decode.field "categories" (Decode.list Decode.string))
            (Decode.field "serving_size_g" (Decode.nullable Decode.string))
            (Decode.field "default_quantity" (Decode.nullable Decode.string))
            (Decode.field "default_unit" (Decode.nullable Decode.string))
            (Decode.field "nutrients" (Decode.list draftNutrientDecoder))
            (Decode.field "servings" (Decode.list draftServingDecoder))


draftNutrientDecoder : Decoder DraftNutrient
draftNutrientDecoder =
    strictObject [ "code", "amount_per_100g" ] <|
        Decode.map2 DraftNutrient
            (Decode.field "code" Decode.string)
            (Decode.field "amount_per_100g" Decode.string)


draftServingDecoder : Decoder DraftServing
draftServingDecoder =
    strictObject [ "label", "quantity", "unit", "grams" ] <|
        Decode.map4 DraftServing
            (Decode.field "label" Decode.string)
            (Decode.field "quantity" Decode.string)
            (Decode.field "unit" Decode.string)
            (Decode.field "grams" Decode.string)


strictObject : List String -> Decoder a -> Decoder a
strictObject expected decoder =
    Decode.keyValuePairs Decode.value
        |> Decode.andThen
            (\entries ->
                let
                    keys : List String
                    keys =
                        List.map Tuple.first entries
                in
                if
                    List.length keys
                        == List.length expected
                        && List.all (\key -> List.member key expected) keys
                then
                    decoder

                else
                    Decode.fail "Unexpected or missing food-assistant response fields"
            )


userTurn : String -> Result String ConversationTurn
userTurn =
    boundedTurn User


assistantTurn : String -> Result String ConversationTurn
assistantTurn =
    boundedTurn Assistant


boundedTurn : ConversationRole -> String -> Result String ConversationTurn
boundedTurn role raw =
    let
        value : String
        value =
            String.trim raw
    in
    if String.isEmpty value then
        Err "A conversation message is required."

    else if String.length value > 4000 then
        Err "Conversation messages must be 4,000 characters or fewer."

    else
        Ok (ConversationTurn role value)


conversation : List ConversationTurn -> Result String Conversation
conversation turns =
    if List.isEmpty turns then
        Err "A conversation must contain a message."

    else if List.length turns > 20 then
        Err "This conversation is full. Start a new assistant session."

    else
        Ok (Conversation turns)


turnRole : ConversationTurn -> ConversationRole
turnRole (ConversationTurn role _) =
    role


turnText : ConversationTurn -> String
turnText (ConversationTurn _ value) =
    value


assistantMessage : FoodDraftTurn -> String
assistantMessage turn =
    case turn of
        NeedsClarification details ->
            details.assistantMessage

        DraftReady details ->
            details.assistantMessage


conversationEncoder : Conversation -> Encode.Value
conversationEncoder (Conversation turns) =
    Encode.object
        [ ( "turns", Encode.list conversationTurnEncoder turns ) ]


conversationTurnEncoder : ConversationTurn -> Encode.Value
conversationTurnEncoder (ConversationTurn role value) =
    Encode.object
        [ ( "role"
          , Encode.string
                (case role of
                    User ->
                        "user"

                    Assistant ->
                        "assistant"
                )
          )
        , ( "text", Encode.string value )
        ]
