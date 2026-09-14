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
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    readyJson
                    |> Result.map
                        (\turn ->
                            case turn of
                                DraftReady result ->
                                    ( result.draft.defaultQuantity
                                    , List.map .amountPer100g result.draft.nutrients
                                    )

                                NeedsClarification _ ->
                                    ( Nothing, [] )
                        )
                    |> Expect.equal (Ok ( Just "1", [ "172.125" ] ))
        , test "rejects inconsistent clarification state" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    (String.replace
                        "\"status\":\"draft_ready\""
                        "\"status\":\"needs_clarification\""
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "rejects unknown response fields" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    (String.replace
                        "\"warnings\":[]"
                        "\"warnings\":[],\"internal\":true"
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "trusts backend-owned draft semantics but requires decimal strings" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    (String.replace
                        "\"default_quantity\":\"1\""
                        "\"default_quantity\":\"not revalidated here\""
                        readyJson
                    )
                    |> Result.map
                        (\turn ->
                            case turn of
                                DraftReady result ->
                                    result.draft.defaultQuantity

                                NeedsClarification _ ->
                                    Nothing
                        )
                    |> Expect.equal (Ok (Just "not revalidated here"))
        , test "rejects numeric decimals because the backend contract uses strings" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    (String.replace
                        "\"default_quantity\":\"1\""
                        "\"default_quantity\":1"
                        readyJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "decodes a required suggested portion for ad-hoc logging" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.AdHocLog)
                    readyLogJson
                    |> Result.map
                        (\turn ->
                            case turn of
                                DraftReady result ->
                                    result.suggestedLog

                                NeedsClarification _ ->
                                    Nothing
                        )
                    |> Expect.equal
                        (Ok
                            (Just
                                { amount = "1"
                                , unit = "bowl"
                                , totalWeightGrams = "350.50"
                                }
                            )
                        )
        , test "ad-hoc logging rejects a ready draft without a suggested portion" <|
            \_ ->
                Decode.decodeString
                    (FoodAssistant.foodDraftTurnDecoder FoodAssistant.AdHocLog)
                    readyJson
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "decodes and preserves image capability" <|
            \_ ->
                Decode.decodeString FoodAssistant.assistantStatusDecoder
                    "{\"enabled\":true,\"supports_images\":true}"
                    |> Expect.equal (Ok { enabled = True, supportsImages = True })
        , test "conversation is encoded with only bounded turns" <|
            \_ ->
                FoodAssistant.userTurn "  one bowl of dal  "
                    |> Result.andThen (\turn -> FoodAssistant.conversation [ turn ])
                    |> Result.map FoodAssistant.conversationEncoder
                    |> Result.map (Encode.encode 0)
                    |> Expect.equal
                        (Ok
                            (String.concat
                                [ "{\"purpose\":\"custom_food\",\"turns\":["
                                , "{\"role\":\"user\",\"text\":\"one bowl of dal\"}]}"
                                ]
                            )
                        )
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
        , "\"categories\":[\"lentils\"],"
        , "\"default_quantity\":\"1\",\"default_unit\":\"bowl\","
        , "\"nutrients\":[{\"code\":\"ENERGY_KCAL\","
        , "\"amount_per_100g\":\"172.125\"}],"
        , "\"servings\":[{\"unit\":\"bowl\","
        , "\"grams_per_unit\":\"350.50\"}]},\"warnings\":[]}"
        ]


readyLogJson : String
readyLogJson =
    String.replace
        ",\"warnings\":[]"
        (String.concat
            [ ",\"suggested_log\":{\"amount\":\"1\",\"unit\":\"bowl\","
            , "\"total_weight_grams\":\"350.50\"},\"warnings\":[]"
            ]
        )
        readyJson
