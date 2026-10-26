module Data.ApiKeyTest exposing (tests)

import Data.ApiKey as ApiKey exposing (ApiKeyScope(..), CreatableScope(..))
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Data.ApiKey"
        [ test "decodes metadata with nullable timestamps and an unknown scope" <|
            \_ ->
                Decode.decodeString ApiKey.decoder metadataJson
                    |> Result.map
                        (\key ->
                            { name = key.name
                            , tokenHint = key.tokenHint
                            , scope = key.scope
                            , lastUsedAt = key.lastUsedAt
                            , expiresAt = key.expiresAt
                            }
                        )
                    |> Expect.equal
                        (Ok
                            { name = "Build script"
                            , tokenHint = "calco_pat_1234abcd"
                            , scope = UnknownScope
                            , lastUsedAt = Nothing
                            , expiresAt = Nothing
                            }
                        )
        , test "decodes a list response with both known scopes" <|
            \_ ->
                Decode.decodeString ApiKey.listDecoder listJson
                    |> Result.map (List.map (\key -> ( key.name, key.scope )))
                    |> Expect.equal
                        (Ok
                            [ ( "Build script", Read )
                            , ( "Phone shortcut", ReadWrite )
                            ]
                        )
        , test "decodes the raw token only from the create response" <|
            \_ ->
                Decode.decodeString ApiKey.createdDecoder createdJson
                    |> Result.map (\created -> ( created.apiKey.name, created.token ))
                    |> Expect.equal (Ok ( "Build script", "token-once" ))
        , test "a create response without a token is rejected" <|
            \_ ->
                Decode.decodeString ApiKey.createdDecoder missingTokenJson
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "encodes a create request with the scope and expiry" <|
            \_ ->
                ApiKey.createRequestEncoder
                    { name = "Build script"
                    , scope = CreatableReadWrite
                    , expiresInDays = Just 90
                    }
                    |> Encode.encode 0
                    |> Expect.equal
                        ("{\"name\":\"Build script\",\"scope\":\"read_write\","
                            ++ "\"expires_in_days\":90}"
                        )
        , test "encodes the 30-day and 1-year expiry choices" <|
            \_ ->
                [ 30, 365 ]
                    |> List.map
                        (\days ->
                            ApiKey.createRequestEncoder
                                { name = "Build script"
                                , scope = CreatableRead
                                , expiresInDays = Just days
                                }
                                |> Encode.encode 0
                        )
                    |> Expect.equal
                        [ "{\"name\":\"Build script\",\"scope\":\"read\","
                            ++ "\"expires_in_days\":30}"
                        , "{\"name\":\"Build script\",\"scope\":\"read\","
                            ++ "\"expires_in_days\":365}"
                        ]
        , test "omits expires_in_days for a never-expiring key" <|
            \_ ->
                ApiKey.createRequestEncoder
                    { name = "Build script"
                    , scope = CreatableRead
                    , expiresInDays = Nothing
                    }
                    |> Encode.encode 0
                    |> Expect.equal "{\"name\":\"Build script\",\"scope\":\"read\"}"
        ]


metadataJson : String
metadataJson =
    """
    {
      "id": "key-1",
      "name": "Build script",
      "token_hint": "calco_pat_1234abcd",
      "scope": "future_scope",
      "created_at": "2026-10-26T10:00:00Z",
      "last_used_at": null,
      "expires_at": null
    }
    """


listJson : String
listJson =
    """
    {
      "items": [
        {
          "id": "key-1",
          "name": "Build script",
          "token_hint": "calco_pat_1234abcd",
          "scope": "read",
          "created_at": "2026-10-26T10:00:00Z",
          "last_used_at": null,
          "expires_at": null
        },
        {
          "id": "key-2",
          "name": "Phone shortcut",
          "token_hint": "calco_pat_5678efgh",
          "scope": "read_write",
          "created_at": "2026-10-25T09:00:00Z",
          "last_used_at": "2026-10-25T09:30:00Z",
          "expires_at": "2027-01-24T10:00:00Z"
        }
      ]
    }
    """


createdJson : String
createdJson =
    """
    {
      "id": "key-1",
      "name": "Build script",
      "token_hint": "calco_pat_1234abcd",
      "scope": "read",
      "created_at": "2026-10-26T10:00:00Z",
      "last_used_at": null,
      "expires_at": "2027-01-24T10:00:00Z",
      "token": "token-once"
    }
    """


missingTokenJson : String
missingTokenJson =
    """
    {
      "id": "key-1",
      "name": "Build script",
      "token_hint": "calco_pat_1234abcd",
      "scope": "read",
      "created_at": "2026-10-26T10:00:00Z",
      "last_used_at": null,
      "expires_at": "2027-01-24T10:00:00Z"
    }
    """
