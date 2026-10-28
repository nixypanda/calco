module Component.FoodAssistantTest exposing (tests)

import Component.FoodAssistant as Assistant
import Data.FoodAssistant as FoodAssistant
    exposing
        ( ConversationRole(..)
        , ConversationTurn
        , FoodDraftPurpose(..)
        )
import Expect
import Fuzz
import I18n
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.ListExtra as ListExtra
import Test exposing (Test, describe, fuzz, fuzz2, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Component.FoodAssistant"
        [ turnRules
        , conversationBounds
        , photoMetadataLimits
        , conversationEncoderBranches
        , conversationEncoderDefault
        , strictObjectRejection
        ]


{-| Pure request rule: turns trim their text and enforce the 4000-character
bound. The expected values are derived independently from the raw string.
-}
turnRules : Test
turnRules =
    fuzz (Fuzz.oneOf [ Fuzz.string, overlongText ])
        "turns trim text and reject blank or overlong input"
    <|
        \raw ->
            let
                trimmed : String
                trimmed =
                    String.trim raw

                expectedUser : Result String ( ConversationRole, String )
                expectedUser =
                    if String.isEmpty trimmed then
                        Err (I18n.en TidAssistantConversationMessageRequired)

                    else if String.length trimmed > 4000 then
                        Err (I18n.en TidAssistantConversationMessageTooLong)

                    else
                        Ok ( User, trimmed )

                expectedAssistant : Result String ( ConversationRole, String )
                expectedAssistant =
                    Result.map (\( _, text ) -> ( Assistant, text )) expectedUser
            in
            Expect.all
                [ \_ ->
                    FoodAssistant.userTurn raw
                        |> toRoleAndText
                        |> Expect.equal expectedUser
                , \_ ->
                    FoodAssistant.assistantTurn raw
                        |> toRoleAndText
                        |> Expect.equal expectedAssistant
                ]
                ()


conversationBounds : Test
conversationBounds =
    test "a conversation requires between 1 and 20 turns" <|
        \_ ->
            Expect.all
                [ \_ ->
                    conversationOf 0
                        |> Expect.equal (Err (I18n.en TidAssistantConversationEmpty))
                , \_ ->
                    conversationOf 1
                        |> Result.map (always ())
                        |> Expect.equal (Ok ())
                , \_ ->
                    conversationOf 20
                        |> Result.map (always ())
                        |> Expect.equal (Ok ())
                , \_ ->
                    conversationOf 21
                        |> Expect.equal (Err (I18n.en TidAssistantConversationFull))
                ]
                ()


photoMetadataLimits : Test
photoMetadataLimits =
    test "photo metadata enforces count, type, per-file, and total limits" <|
        \_ ->
            let
                mebibyte : Int
                mebibyte =
                    1024 * 1024

                photo : String -> Int -> Assistant.PhotoMeta
                photo mimeType size =
                    { mimeType = mimeType, size = size }

                fourAtTen : List Assistant.PhotoMeta
                fourAtTen =
                    List.repeat 4 (photo "image/jpeg" (10 * mebibyte))
            in
            Expect.all
                [ \_ ->
                    Assistant.validatePhotoMeta []
                        [ photo "image/jpeg" (15 * mebibyte) ]
                        |> Expect.equal (Ok ())
                , \_ ->
                    Assistant.validatePhotoMeta fourAtTen []
                        |> Expect.equal (Ok ())
                , \_ ->
                    Assistant.validatePhotoMeta []
                        [ photo "image/gif" 1 ]
                        |> Expect.equal (Err (I18n.en TidAssistantPhotoTypes))
                , \_ ->
                    Assistant.validatePhotoMeta []
                        [ photo "image/png" (15 * mebibyte + 1) ]
                        |> Expect.equal (Err (I18n.en TidAssistantPhotoTooLarge))
                , \_ ->
                    Assistant.validatePhotoMeta fourAtTen
                        [ photo "image/png" 1 ]
                        |> Expect.equal (Err (I18n.en TidAssistantPhotoLimit))
                , \_ ->
                    Assistant.validatePhotoMeta
                        [ photo "image/jpeg" (15 * mebibyte)
                        , photo "image/png" (15 * mebibyte)
                        ]
                        [ photo "image/webp" (10 * mebibyte + 1) ]
                        |> Expect.equal (Err (I18n.en TidAssistantPhotosTotalTooLarge))
                ]
                ()


{-| Request encoder branch property: both purposes are encoded, and every
turn keeps its role, text, and position.
-}
conversationEncoderBranches : Test
conversationEncoderBranches =
    fuzz2
        (Fuzz.oneOfValues [ CustomFood, AdHocLog ])
        (Fuzz.listOfLengthBetween 1 20 encodedTurn)
        "the conversation encoder preserves purpose, role, text, and order"
    <|
        \purpose pairs ->
            let
                turns : Result String (List ConversationTurn)
                turns =
                    pairs
                        |> List.map
                            (\( isUser, text ) ->
                                if isUser then
                                    FoodAssistant.userTurn text

                                else
                                    FoodAssistant.assistantTurn text
                            )
                        |> ListExtra.combineErrors

                expected : EncodedConversation
                expected =
                    { purpose = purposeCode purpose
                    , turns =
                        List.map
                            (\( isUser, text ) ->
                                ( if isUser then
                                    "user"

                                  else
                                    "assistant"
                                , text
                                )
                            )
                            pairs
                    }
            in
            turns
                |> Result.andThen FoodAssistant.conversation
                |> Result.map (FoodAssistant.conversationEncoderFor purpose)
                |> Result.map decodeEncodedConversation
                |> Result.andThen identity
                |> Expect.equal (Ok expected)


{-| The public alias without an explicit purpose uses `custom_food`.
-}
conversationEncoderDefault : Test
conversationEncoderDefault =
    test "conversationEncoder defaults to the custom_food purpose" <|
        \_ ->
            FoodAssistant.userTurn "dal"
                |> Result.andThen (\turn -> FoodAssistant.conversation [ turn ])
                |> Result.map FoodAssistant.conversationEncoder
                |> Result.map
                    (Decode.decodeValue (Decode.field "purpose" Decode.string))
                |> Expect.equal (Ok (Ok "custom_food"))


{-| Exception from §6.5: the draft decoder intentionally rejects unknown
fields, so this negative invariant cannot be expressed as a roundtrip. The
valid payload proves the rejection is caused by the extra key alone.
-}
strictObjectRejection : Test
strictObjectRejection =
    test "the draft decoder rejects an otherwise valid payload with an extra key" <|
        \_ ->
            let
                payload : List ( String, Encode.Value )
                payload =
                    [ ( "assistant_message", Encode.string "How much?" )
                    , ( "status", Encode.string "needs_clarification" )
                    , ( "draft", Encode.null )
                    , ( "warnings", Encode.list Encode.string [] )
                    ]

                decode : Encode.Value -> Maybe ()
                decode value =
                    Decode.decodeValue
                        (FoodAssistant.foodDraftTurnDecoder CustomFood)
                        value
                        |> Result.map (always ())
                        |> Result.toMaybe
            in
            Expect.all
                [ \_ -> decode (Encode.object payload) |> Expect.equal (Just ())
                , \_ ->
                    decode
                        (Encode.object
                            (payload
                                ++ [ ( "unexpected", Encode.string "nope" ) ]
                            )
                        )
                        |> Expect.equal Nothing
                ]
                ()



-- HELPERS


type alias EncodedConversation =
    { purpose : String, turns : List ( String, String ) }


encodedConversationDecoder : Decode.Decoder EncodedConversation
encodedConversationDecoder =
    Decode.map2 EncodedConversation
        (Decode.field "purpose" Decode.string)
        (Decode.field "turns" (Decode.list encodedTurnDecoder))


encodedTurnDecoder : Decode.Decoder ( String, String )
encodedTurnDecoder =
    Decode.map2 Tuple.pair
        (Decode.field "role" Decode.string)
        (Decode.field "text" Decode.string)


decodeEncodedConversation : Encode.Value -> Result String EncodedConversation
decodeEncodedConversation value =
    case Decode.decodeValue encodedConversationDecoder value of
        Ok conversation ->
            Ok conversation

        Err _ ->
            Err "conversation encoder produced an unexpected shape"


encodedTurn : Fuzz.Fuzzer ( Bool, String )
encodedTurn =
    Fuzz.map2 Tuple.pair
        Fuzz.bool
        (Fuzz.map
            (\index -> "turn " ++ String.fromInt index)
            (Fuzz.intRange 1 100000)
        )


overlongText : Fuzz.Fuzzer String
overlongText =
    Fuzz.map3
        (\leading length trailing ->
            String.repeat leading " "
                ++ String.repeat length "x"
                ++ String.repeat trailing " "
        )
        (Fuzz.intRange 0 4)
        (Fuzz.intRange 3999 4001)
        (Fuzz.intRange 0 4)


toRoleAndText : Result String ConversationTurn -> Result String ( ConversationRole, String )
toRoleAndText turn =
    turn
        |> Result.map
            (\value ->
                ( FoodAssistant.turnRole value
                , FoodAssistant.turnText value
                )
            )


conversationOf : Int -> Result String FoodAssistant.Conversation
conversationOf count =
    List.range 1 (max 0 count)
        |> List.map
            (\index ->
                FoodAssistant.userTurn ("turn " ++ String.fromInt index)
            )
        |> ListExtra.combineErrors
        |> Result.andThen FoodAssistant.conversation


purposeCode : FoodDraftPurpose -> String
purposeCode purpose =
    case purpose of
        CustomFood ->
            "custom_food"

        AdHocLog ->
            "ad_hoc_log"
