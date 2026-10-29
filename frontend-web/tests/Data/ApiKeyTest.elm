module Data.ApiKeyTest exposing (tests)

import Data.ApiKey as ApiKey exposing (ApiKeyScope(..), CreatableScope(..))
import Dict exposing (Dict)
import Expect
import Fuzz
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Data.ApiKey"
        [ fuzz createRequestFuzzer
            "createRequestEncoder keeps the name, maps the scope, and includes expiry only when set"
          <|
            \request ->
                let
                    encoded : Encode.Value
                    encoded =
                        ApiKey.createRequestEncoder request
                in
                case Decode.decodeValue (Decode.dict Decode.value) encoded of
                    Err _ ->
                        Expect.fail "createRequestEncoder did not produce a JSON object"

                    Ok fields ->
                        Expect.all
                            (List.map always
                                [ expectField "name" Decode.string request.name fields
                                , expectField "scope" Decode.string (scopeCode request.scope) fields
                                , case request.expiresInDays of
                                    Just days ->
                                        expectField "expires_in_days" Decode.int days fields

                                    Nothing ->
                                        Dict.member "expires_in_days" fields |> Expect.equal False
                                ]
                            )
                            ()

        {- This is one of the three allowed negative decoder invariants from
           the overhaul plan (§6.5): an unrecognised server scope must degrade
           to `UnknownScope` instead of rejecting the metadata. It survives
           because the fallback is deliberate leniency, not field-by-field
           decoder restatement.
        -}
        , test "decoder maps an unknown scope to UnknownScope" <|
            \_ ->
                metadataWithScope "future_scope"
                    |> Decode.decodeValue ApiKey.decoder
                    |> Result.map .scope
                    |> Expect.equal (Ok UnknownScope)
        ]


createRequestFuzzer : Fuzz.Fuzzer ApiKey.CreateRequest
createRequestFuzzer =
    Fuzz.map3
        (\name scope expiresInDays ->
            { name = name, scope = scope, expiresInDays = expiresInDays }
        )
        Fuzz.string
        (Fuzz.oneOfValues [ CreatableRead, CreatableReadWrite ])
        (Fuzz.maybe (Fuzz.intRange 0 3650))


scopeCode : CreatableScope -> String
scopeCode scope =
    case scope of
        CreatableRead ->
            "read"

        CreatableReadWrite ->
            "read_write"


expectField : String -> Decode.Decoder a -> a -> Dict String Decode.Value -> Expect.Expectation
expectField key decoder expected fields =
    case Dict.get key fields of
        Just raw ->
            Decode.decodeValue decoder raw |> Expect.equal (Ok expected)

        Nothing ->
            Expect.fail ("missing encoded key: " ++ key)


metadataWithScope : String -> Decode.Value
metadataWithScope scope =
    Encode.object
        [ ( "id", Encode.string "key-1" )
        , ( "name", Encode.string "Build script" )
        , ( "token_hint", Encode.string "calco_pat_1234abcd" )
        , ( "scope", Encode.string scope )
        , ( "created_at", Encode.string "2026-10-26T10:00:00Z" )
        , ( "last_used_at", Encode.null )
        , ( "expires_at", Encode.null )
        ]
