module Data.FoodAssistantTest exposing (tests)

import Data.FoodAssistant as FoodAssistant exposing (FoodDraftTurn(..))
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.FoodAssistant"
        [ test "decodes a ready draft with decimal strings" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder readyJson
                    |> Result.map
                        (\turn ->
                            case turn of
                                DraftReady result ->
                                    ( result.draft.servingSizeG
                                    , List.map .amountPer100g result.draft.nutrients
                                    )

                                NeedsClarification _ ->
                                    ( Nothing, [] )
                        )
                    |> Expect.equal (Ok ( Just "350.50", [ "172.125" ] ))
        , test "rejects inconsistent clarification state" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder
                    (String.replace
                        "\"status\":\"draft_ready\""
                        "\"status\":\"needs_clarification\""
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "rejects unknown response fields" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder
                    (String.replace
                        "\"warnings\":[]"
                        "\"warnings\":[],\"internal\":true"
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "trusts backend-owned draft semantics but requires decimal strings" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder
                    (String.replace
                        "\"serving_size_g\":\"350.50\""
                        "\"serving_size_g\":\"not revalidated here\""
                        readyJson
                    )
                    |> Result.map
                        (\turn ->
                            case turn of
                                DraftReady result ->
                                    result.draft.servingSizeG

                                NeedsClarification _ ->
                                    Nothing
                        )
                    |> Expect.equal (Ok (Just "not revalidated here"))
        , test "rejects numeric decimals because the backend contract uses strings" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder
                    (String.replace
                        "\"serving_size_g\":\"350.50\""
                        "\"serving_size_g\":350.50"
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "rejects image capability in the text-only status" <|
            \_ ->
                Decode.decodeString FoodAssistant.assistantStatusDecoder
                    "{\"enabled\":true,\"supports_images\":true}"
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "conversation is encoded with only bounded turns" <|
            \_ ->
                FoodAssistant.userTurn "  one bowl of dal  "
                    |> Result.andThen (\turn -> FoodAssistant.conversation [ turn ])
                    |> Result.map FoodAssistant.conversationEncoder
                    |> Result.map (Encode.encode 0)
                    |> Expect.equal
                        (Ok "{\"turns\":[{\"role\":\"user\",\"text\":\"one bowl of dal\"}]}")
        , test "conversation rejects more than twenty turns" <|
            \_ ->
                FoodAssistant.userTurn "dal"
                    |> Result.andThen
                        (\turn -> FoodAssistant.conversation (List.repeat 21 turn))
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        ]


readyJson : String
readyJson =
    String.concat
        [ "{\"assistant_message\":\"Review this estimate.\","
        , "\"status\":\"draft_ready\","
        , "\"draft\":{\"name\":\"Dal\",\"brand\":null,"
        , "\"categories\":[\"lentils\"],\"serving_size_g\":\"350.50\","
        , "\"default_quantity\":\"1\",\"default_unit\":\"bowl\","
        , "\"nutrients\":[{\"code\":\"ENERGY_KCAL\","
        , "\"amount_per_100g\":\"172.125\"}],"
        , "\"servings\":[{\"label\":\"one bowl\",\"quantity\":\"1\","
        , "\"unit\":\"bowl\",\"grams\":\"350.50\"}]},\"warnings\":[]}"
        ]
