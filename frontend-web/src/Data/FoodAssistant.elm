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
    { enabled : Bool }


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
        (Decode.map2 Tuple.pair
            (Decode.field "enabled" Decode.bool)
            (Decode.field "supports_images" Decode.bool)
            |> Decode.andThen
                (\( enabled, supportsImages ) ->
                    if supportsImages then
                        Decode.fail "Image support is outside the text assistant contract"

                    else
                        Decode.succeed { enabled = enabled }
                )
        )


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
                (Decode.field "assistant_message" nonEmptyStringDecoder)
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
                (Decode.field "assistant_message" nonEmptyStringDecoder)
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
        (Decode.map8 FoodDraft
            (Decode.field "name" nonEmptyStringDecoder)
            (Decode.field "brand" (Decode.nullable nonEmptyStringDecoder))
            (Decode.field "categories" (Decode.list nonEmptyStringDecoder))
            (Decode.field "serving_size_g" (Decode.nullable positiveDecimalDecoder))
            (Decode.field "default_quantity" (Decode.nullable positiveDecimalDecoder))
            (Decode.field "default_unit" (Decode.nullable nonEmptyStringDecoder))
            (Decode.field "nutrients" (Decode.list draftNutrientDecoder))
            (Decode.field "servings" (Decode.list draftServingDecoder))
            |> Decode.andThen
                (\draft ->
                    if
                        Maybe.map (always ()) draft.defaultQuantity
                            == Maybe.map (always ()) draft.defaultUnit
                    then
                        Decode.succeed draft

                    else
                        Decode.fail "Default quantity and unit must be supplied together"
                )
        )


draftNutrientDecoder : Decoder DraftNutrient
draftNutrientDecoder =
    strictObject [ "code", "amount_per_100g" ] <|
        Decode.map2 DraftNutrient
            (Decode.field "code" nonEmptyStringDecoder)
            (Decode.field "amount_per_100g" nonNegativeDecimalDecoder)


draftServingDecoder : Decoder DraftServing
draftServingDecoder =
    strictObject [ "label", "quantity", "unit", "grams" ] <|
        Decode.map4 DraftServing
            (Decode.field "label" nonEmptyStringDecoder)
            (Decode.field "quantity" positiveDecimalDecoder)
            (Decode.field "unit" nonEmptyStringDecoder)
            (Decode.field "grams" positiveDecimalDecoder)


positiveDecimalDecoder : Decoder String
positiveDecimalDecoder =
    decimalDecoder
        |> Decode.andThen
            (\value ->
                if Maybe.withDefault 0 (String.toFloat value) > 0 then
                    Decode.succeed value

                else
                    Decode.fail "Expected a positive decimal"
            )


nonNegativeDecimalDecoder : Decoder String
nonNegativeDecimalDecoder =
    decimalDecoder
        |> Decode.andThen
            (\value ->
                if Maybe.withDefault -1 (String.toFloat value) >= 0 then
                    Decode.succeed value

                else
                    Decode.fail "Expected a non-negative decimal"
            )


decimalDecoder : Decoder String
decimalDecoder =
    Decode.oneOf
        [ Decode.string
        , Decode.float |> Decode.map String.fromFloat
        ]
        |> Decode.andThen
            (\raw ->
                let
                    value : String
                    value =
                        String.trim raw
                in
                case String.toFloat value of
                    Just _ ->
                        Decode.succeed value

                    Nothing ->
                        Decode.fail "Invalid decimal"
            )


nonEmptyStringDecoder : Decoder String
nonEmptyStringDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                let
                    value : String
                    value =
                        String.trim raw
                in
                if String.isEmpty value then
                    Decode.fail "Expected non-empty text"

                else
                    Decode.succeed value
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
