module Data.ApiKey exposing
    ( ApiKey
    , ApiKeyScope(..)
    , CreatableScope(..)
    , CreateRequest
    , CreatedApiKey
    , createRequestEncoder
    , createdDecoder
    , decoder
    , listDecoder
    )

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type ApiKeyScope
    = Read
    | ReadWrite
    | UnknownScope


{-| A scope that can be sent to the create endpoint. Keeping this separate
from `ApiKeyScope` prevents an unknown scope returned by the list endpoint from
being reused in a create request.
-}
type CreatableScope
    = CreatableRead
    | CreatableReadWrite


type alias ApiKey =
    { id : String
    , name : String
    , tokenHint : String
    , scope : ApiKeyScope
    , createdAt : String
    , lastUsedAt : Maybe String
    , expiresAt : Maybe String
    }


type alias CreatedApiKey =
    { apiKey : ApiKey
    , token : String
    }


type alias CreateRequest =
    { name : String
    , scope : CreatableScope
    , expiresInDays : Maybe Int
    }


decoder : Decoder ApiKey
decoder =
    Decode.map7 ApiKey
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "token_hint" Decode.string)
        (Decode.field "scope" scopeDecoder)
        (Decode.field "created_at" Decode.string)
        (Decode.field "last_used_at" (Decode.nullable Decode.string))
        (Decode.field "expires_at" (Decode.nullable Decode.string))


createdDecoder : Decoder CreatedApiKey
createdDecoder =
    Decode.map2 CreatedApiKey decoder (Decode.field "token" Decode.string)


listDecoder : Decoder (List ApiKey)
listDecoder =
    Decode.field "items" (Decode.list decoder)


createRequestEncoder : CreateRequest -> Encode.Value
createRequestEncoder request =
    Encode.object
        ([ ( "name", Encode.string request.name )
         , ( "scope", Encode.string (creatableScopeToString request.scope) )
         ]
            ++ (case request.expiresInDays of
                    Just days ->
                        [ ( "expires_in_days", Encode.int days ) ]

                    Nothing ->
                        []
               )
        )


scopeDecoder : Decoder ApiKeyScope
scopeDecoder =
    Decode.map scopeFromString Decode.string


scopeFromString : String -> ApiKeyScope
scopeFromString raw =
    case raw of
        "read" ->
            Read

        "read_write" ->
            ReadWrite

        _ ->
            UnknownScope


creatableScopeToString : CreatableScope -> String
creatableScopeToString scope =
    case scope of
        CreatableRead ->
            "read"

        CreatableReadWrite ->
            "read_write"
