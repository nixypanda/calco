module JsonDecoderTest exposing (tests)

import Data.Auth as Auth
import Data.ItemRef as ItemRef
import Data.Quantity as Quantity
import Data.User as User
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "JSON contracts"
        [ test "decodes bootstrap status" <|
            \_ ->
                Decode.decodeString Auth.bootstrapStatusDecoder "{ \"admin_exists\": false }"
                    |> Result.map .adminExists
                    |> Expect.equal (Ok False)
        , test "decodes login session with null profile" <|
            \_ ->
                Decode.decodeString Auth.loginSessionDecoder "{ \"identity\": { \"id\": \"1\", \"username\": \"admin\", \"role\": \"admin\" }, \"profile\": null }"
                    |> Result.map .profile
                    |> Expect.equal (Ok Nothing)
        , test "encodes login request" <|
            \_ ->
                Auth.loginRequestEncoder { username = "alice", password = "secret" }
                    |> Encode.encode 0
                    |> Expect.equal "{\"username\":\"alice\",\"password\":\"secret\"}"
        , test "decodes quantity" <|
            \_ ->
                Decode.decodeString Quantity.decoder "{ \"amount\": \"1.5\", \"unit\": \"g\" }"
                    |> Expect.equal (Ok { amount = "1.5", unit = "g" })
        , test "decodes item ref" <|
            \_ ->
                Decode.decodeString ItemRef.decoder "{ \"type\": \"product\", \"id\": \"p1\" }"
                    |> Expect.equal (Ok { itemType = "product", id = "p1" })
        , test "decodes admin user list" <|
            \_ ->
                Decode.decodeString User.listUsersDecoder "{ \"users\": [{ \"id\": \"u1\", \"username\": \"alice\", \"display_name\": \"Alice\", \"status\": \"active\", \"created_at\": \"now\" }] }"
                    |> Result.map List.length
                    |> Expect.equal (Ok 1)
        ]
