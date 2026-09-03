module Data.FoodAssistant exposing
    ( AssistantStatus
    , Conversation
    , ConversationRole(..)
    , ConversationTurn
    , DraftNutrient
    , DraftServing
    , DraftStatus(..)
    , FoodDraft
    , FoodDraftTurn
    , assistantStatusDecoder
    , conversationEncoder
    , foodDraftTurnDecoder
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


type alias ConversationTurn =
    { role : ConversationRole
    , text : String
    }


type alias Conversation =
    { turns : List ConversationTurn
    }


type DraftStatus
    = NeedsClarification
    | DraftReady


type alias FoodDraft =
    { name : String
    , brand : Maybe String
    , categories : List String
    , servingSizeG : Maybe Float
    , defaultQuantity : Maybe Float
    , defaultUnit : Maybe String
    , nutrients : List DraftNutrient
    , servings : List DraftServing
    }


type alias DraftNutrient =
    { code : String
    , amountPer100g : Float
    }


type alias DraftServing =
    { label : String
    , quantity : Float
    , unit : String
    , grams : Float
    }


type alias FoodDraftTurn =
    { assistantMessage : String
    , status : DraftStatus
    , draft : Maybe FoodDraft
    , warnings : List String
    }


assistantStatusDecoder : Decoder AssistantStatus
assistantStatusDecoder =
    strictObject [ "enabled", "supports_images" ] <|
        Decode.map2 AssistantStatus
            (Decode.field "enabled" Decode.bool)
            (Decode.field "supports_images" Decode.bool)


foodDraftTurnDecoder : Decoder FoodDraftTurn
foodDraftTurnDecoder =
    strictObject [ "assistant_message", "status", "draft", "warnings" ]
        (Decode.map4 FoodDraftTurn
            (Decode.field "assistant_message" Decode.string)
            (Decode.field "status" draftStatusDecoder)
            (Decode.field "draft" (Decode.nullable foodDraftDecoder))
            (Decode.field "warnings" (Decode.list Decode.string))
            |> Decode.andThen validateDraftTurn
        )


validateDraftTurn : FoodDraftTurn -> Decoder FoodDraftTurn
validateDraftTurn turn =
    case ( turn.status, turn.draft ) of
        ( NeedsClarification, Nothing ) ->
            Decode.succeed turn

        ( DraftReady, Just _ ) ->
            Decode.succeed turn

        _ ->
            Decode.fail "Food-assistant status and draft do not match"


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
            (Decode.field "serving_size_g" (Decode.nullable decimalDecoder))
            (Decode.field "default_quantity" (Decode.nullable decimalDecoder))
            (Decode.field "default_unit" (Decode.nullable Decode.string))
            (Decode.field "nutrients" (Decode.list draftNutrientDecoder))
            (Decode.field "servings" (Decode.list draftServingDecoder))


draftNutrientDecoder : Decoder DraftNutrient
draftNutrientDecoder =
    strictObject [ "code", "amount_per_100g" ] <|
        Decode.map2 DraftNutrient
            (Decode.field "code" Decode.string)
            (Decode.field "amount_per_100g" decimalDecoder)


draftServingDecoder : Decoder DraftServing
draftServingDecoder =
    strictObject [ "label", "quantity", "unit", "grams" ] <|
        Decode.map4 DraftServing
            (Decode.field "label" Decode.string)
            (Decode.field "quantity" decimalDecoder)
            (Decode.field "unit" Decode.string)
            (Decode.field "grams" decimalDecoder)


decimalDecoder : Decoder Float
decimalDecoder =
    Decode.oneOf
        [ Decode.float
        , Decode.string
            |> Decode.andThen
                (\raw ->
                    case String.toFloat raw of
                        Just value ->
                            Decode.succeed value

                        Nothing ->
                            Decode.fail ("Invalid decimal string: " ++ raw)
                )
        ]


draftStatusDecoder : Decoder DraftStatus
draftStatusDecoder =
    Decode.string
        |> Decode.andThen
            (\value ->
                case value of
                    "needs_clarification" ->
                        Decode.succeed NeedsClarification

                    "draft_ready" ->
                        Decode.succeed DraftReady

                    _ ->
                        Decode.fail "Unsupported food-assistant draft status"
            )


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


conversationEncoder : Conversation -> Encode.Value
conversationEncoder conversation =
    Encode.object
        [ ( "turns", Encode.list conversationTurnEncoder conversation.turns ) ]


conversationTurnEncoder : ConversationTurn -> Encode.Value
conversationTurnEncoder turn =
    Encode.object
        [ ( "role"
          , Encode.string
                (case turn.role of
                    User ->
                        "user"

                    Assistant ->
                        "assistant"
                )
          )
        , ( "text", Encode.string turn.text )
        ]
