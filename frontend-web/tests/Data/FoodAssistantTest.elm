module Data.FoodAssistantTest exposing (tests)

import Data.FoodAssistant as FoodAssistant
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.FoodAssistant"
        [ test "decodes a complete strict draft" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder completeDraftJson
                    |> Result.map
                        (\turn ->
                            ( turn.assistantMessage
                            , turn.draft |> Maybe.map .name
                            , turn.draft |> Maybe.map (List.length << .nutrients)
                            )
                        )
                    |> Expect.equal
                        (Ok ( "Estimated from your description.", Just "Chicken biryani", Just 4 ))
        , test "rejects extra draft fields" <|
            \_ ->
                Decode.decodeString FoodAssistant.foodDraftTurnDecoder
                    (String.replace
                        "\"servings\":["
                        "\"unexpected\":true,\"servings\":["
                        completeDraftJson
                    )
                    |> Result.mapError (always ())
                    |> Expect.equal (Err ())
        , test "encodes only the backend conversation shape" <|
            \_ ->
                FoodAssistant.conversationEncoder
                    { turns = [ { role = FoodAssistant.User, text = "One bowl of biryani" } ] }
                    |> Encode.encode 0
                    |> Expect.equal
                        "{\"turns\":[{\"role\":\"user\",\"text\":\"One bowl of biryani\"}]}"
        ]


completeDraftJson : String
completeDraftJson =
    String.concat
        [ "{\"assistant_message\":\"Estimated from your description.\",\"status\":\"draft_ready\","
        , "\"draft\":{\"name\":\"Chicken biryani\",\"brand\":null,\"categories\":[\"rice dishes\"],"
        , "\"serving_size_g\":350,\"default_quantity\":1,\"default_unit\":\"serving\","
        , "\"nutrients\":[{\"code\":\"ENERGY_KCAL\",\"amount_per_100g\":172},"
        , "{\"code\":\"PROTEIN_G\",\"amount_per_100g\":8.4},"
        , "{\"code\":\"CARBS_G\",\"amount_per_100g\":22.1},"
        , "{\"code\":\"FAT_G\",\"amount_per_100g\":5.7}],"
        , "\"servings\":[{\"label\":\"1 bowl\",\"quantity\":1,\"unit\":\"serving\","
        , "\"grams\":350}]},"
        , "\"warnings\":[\"Estimated nutrition.\"]}"
        ]
