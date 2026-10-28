module Data.FoodAssistantTest exposing (tests)

import Data.FoodAssistant as FoodAssistant
    exposing
        ( ConversationRole(..)
        , ConversationTurn
        , FoodDraftPurpose(..)
        )
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode
import Json.Encode as Encode
import Support.Fuzz as Support
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.FoodAssistant"
        [ fuzz (Fuzz.map2 Tuple.pair roleFuzzer paddedTextFuzzer)
            "bounded turns trim surrounding whitespace and preserve their role"
          <|
            \( role, raw ) ->
                turnFor role raw
                    |> Result.map
                        (\turn ->
                            ( FoodAssistant.turnRole turn, FoodAssistant.turnText turn )
                        )
                    |> Expect.equal (Ok ( role, String.trim raw ))
        , fuzz blankTextFuzzer "bounded turns reject blank text for both roles" <|
            \raw ->
                ( Result.toMaybe (FoodAssistant.userTurn raw)
                , Result.toMaybe (FoodAssistant.assistantTurn raw)
                )
                    |> Expect.equal ( Nothing, Nothing )
        , fuzz (Fuzz.intRange 4001 8000)
            "bounded turns reject text longer than 4000 characters"
          <|
            \length ->
                let
                    raw : String
                    raw =
                        String.repeat length "a"
                in
                ( Result.toMaybe (FoodAssistant.userTurn raw)
                , Result.toMaybe (FoodAssistant.assistantTurn raw)
                )
                    |> Expect.equal ( Nothing, Nothing )
        , test "bounded turns accept exactly 4000 characters" <|
            \_ ->
                let
                    raw : String
                    raw =
                        String.repeat 4000 "a"

                    summarized :
                        Result String ConversationTurn
                        -> Result String ( ConversationRole, Int )
                    summarized =
                        Result.map
                            (\turn ->
                                ( FoodAssistant.turnRole turn
                                , String.length (FoodAssistant.turnText turn)
                                )
                            )
                in
                ( summarized (FoodAssistant.userTurn raw)
                , summarized (FoodAssistant.assistantTurn raw)
                )
                    |> Expect.equal
                        ( Ok ( User, 4000 ), Ok ( Assistant, 4000 ) )
        , test "bounded turns trim padding before applying the 4000-character limit" <|
            \_ ->
                let
                    summarize :
                        Result String ConversationTurn
                        -> Result String ( ConversationRole, Int )
                    summarize =
                        Result.map
                            (\turn ->
                                ( FoodAssistant.turnRole turn
                                , String.length (FoodAssistant.turnText turn)
                                )
                            )

                    accepted : String
                    accepted =
                        String.repeat 4000 "a" ++ "     "

                    rejected : String
                    rejected =
                        String.repeat 4001 "a" ++ "     "
                in
                Expect.all
                    (List.map always
                        [ summarize (FoodAssistant.userTurn accepted)
                            |> Expect.equal (Ok ( User, 4000 ))
                        , summarize (FoodAssistant.assistantTurn accepted)
                            |> Expect.equal (Ok ( Assistant, 4000 ))
                        , Result.toMaybe (FoodAssistant.userTurn rejected)
                            |> Expect.equal Nothing
                        , Result.toMaybe (FoodAssistant.assistantTurn rejected)
                            |> Expect.equal Nothing
                        ]
                    )
                    ()
        , test "conversation rejects an empty turn list" <|
            \_ ->
                FoodAssistant.conversation []
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , fuzz (Fuzz.intRange 21 40) "conversation rejects more than twenty turns" <|
            \count ->
                FoodAssistant.userTurn "dal"
                    |> Result.andThen
                        (\turn -> FoodAssistant.conversation (List.repeat count turn))
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , fuzz (Fuzz.listOfLengthBetween 1 20 turnSpecFuzzer)
            "conversation accepts one through twenty turns"
          <|
            \specs ->
                case buildTurns specs of
                    Err message ->
                        Expect.fail ("could not build turns: " ++ message)

                    Ok turns ->
                        FoodAssistant.conversation turns
                            |> Result.map (always ())
                            |> Expect.equal (Ok ())
        , fuzz
            (Fuzz.map2 Tuple.pair purposeFuzzer (Fuzz.listOfLengthBetween 1 20 turnSpecFuzzer))
            "conversationEncoderFor preserves purpose and ordered turn roles/text"
          <|
            \( purpose, specs ) ->
                case buildTurns specs of
                    Err message ->
                        Expect.fail ("could not build turns: " ++ message)

                    Ok turns ->
                        case FoodAssistant.conversation turns of
                            Err message ->
                                Expect.fail ("conversation rejected valid turns: " ++ message)

                            Ok conversation ->
                                let
                                    encoded : Decode.Value
                                    encoded =
                                        FoodAssistant.conversationEncoderFor purpose conversation

                                    expectedTurns : List ( String, String )
                                    expectedTurns =
                                        List.map
                                            (\turn ->
                                                ( roleCode (FoodAssistant.turnRole turn)
                                                , FoodAssistant.turnText turn
                                                )
                                            )
                                            turns
                                in
                                Expect.all
                                    (List.map always
                                        [ Decode.decodeValue
                                            (Decode.field "purpose" Decode.string)
                                            encoded
                                            |> Expect.equal (Ok (purposeCode purpose))
                                        , Decode.decodeValue
                                            (Decode.field "turns" (Decode.list turnPairDecoder))
                                            encoded
                                            |> Expect.equal (Ok expectedTurns)
                                        ]
                                    )
                                    ()

        {- This is the allowed food-assistant strict-object exception (§6.5.3).
           The decoder is intentionally stricter than a plain field decoder:
           extra server keys must be rejected so an incompatible assistant
           payload cannot be silently accepted. It is the only response-decoder
           fixture kept here.
        -}
        , test "assistantStatusDecoder rejects an object with an extra key" <|
            \_ ->
                Encode.object
                    [ ( "enabled", Encode.bool True )
                    , ( "supports_images", Encode.bool True )
                    , ( "internal", Encode.bool True )
                    ]
                    |> Decode.decodeValue FoodAssistant.assistantStatusDecoder
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "foodDraftTurnDecoder rejects a valid CustomFood payload with an extra key" <|
            \_ ->
                Encode.object
                    [ ( "assistant_message", Encode.string "Which food?" )
                    , ( "status", Encode.string "needs_clarification" )
                    , ( "draft", Encode.null )
                    , ( "warnings", Encode.list Encode.string [] )
                    , ( "internal", Encode.bool True )
                    ]
                    |> Decode.decodeValue
                        (FoodAssistant.foodDraftTurnDecoder FoodAssistant.CustomFood)
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "conversationEncoder defaults to the custom_food purpose" <|
            \_ ->
                FoodAssistant.userTurn "dal"
                    |> Result.andThen
                        (\turn -> FoodAssistant.conversation [ turn ])
                    |> Result.map FoodAssistant.conversationEncoder
                    |> Result.map
                        (Decode.decodeValue (Decode.field "purpose" Decode.string))
                    |> Expect.equal (Ok (Ok "custom_food"))
        ]


type alias TurnSpec =
    ( ConversationRole, String )


turnSpecFuzzer : Fuzzer TurnSpec
turnSpecFuzzer =
    Fuzz.map2 Tuple.pair roleFuzzer nonBlankText


roleFuzzer : Fuzzer ConversationRole
roleFuzzer =
    Fuzz.oneOfValues [ User, Assistant ]


purposeFuzzer : Fuzzer FoodDraftPurpose
purposeFuzzer =
    Fuzz.oneOfValues [ CustomFood, AdHocLog ]


nonBlankText : Fuzzer String
nonBlankText =
    Fuzz.map (\suffix -> "turn-" ++ suffix) Support.segment


paddedTextFuzzer : Fuzzer String
paddedTextFuzzer =
    Fuzz.map (\text -> " \t" ++ text ++ "\n ") nonBlankText


blankTextFuzzer : Fuzzer String
blankTextFuzzer =
    Fuzz.list (Fuzz.oneOfValues [ ' ', '\t', '\n', '\u{000D}' ])
        |> Fuzz.map String.fromList


buildTurns : List TurnSpec -> Result String (List ConversationTurn)
buildTurns =
    List.foldr
        (\( role, raw ) rest ->
            Result.map2 (::) (turnFor role raw) rest
        )
        (Ok [])


turnFor : ConversationRole -> String -> Result String ConversationTurn
turnFor role raw =
    case role of
        User ->
            FoodAssistant.userTurn raw

        Assistant ->
            FoodAssistant.assistantTurn raw


turnPairDecoder : Decode.Decoder ( String, String )
turnPairDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "role" Decode.string)
        (Decode.field "text" Decode.string)


roleCode : ConversationRole -> String
roleCode role =
    case role of
        User ->
            "user"

        Assistant ->
            "assistant"


purposeCode : FoodDraftPurpose -> String
purposeCode purpose =
    case purpose of
        CustomFood ->
            "custom_food"

        AdHocLog ->
            "ad_hoc_log"
