module JsonDecoderTest exposing (tests)

import Api.Foods as Foods
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
        , test "decodes food search response" <|
            \_ ->
                Decode.decodeString Foods.searchResponseDecoder "{ \"items\": [{ \"id\": \"f1\", \"source\": \"USER\", \"source_id\": null, \"barcode\": \"123\", \"name\": \"Apple\", \"brand\": null, \"categories\": [\"fruit\"], \"serving_size_g\": \"100\", \"energy_kcal_per_100g\": \"52\", \"energy_kcal_per_serving\": null }] }"
                    |> Result.map (.items >> List.map .name)
                    |> Expect.equal (Ok [ "Apple" ])
        , test "builds food search path with encoded query" <|
            \_ ->
                Foods.searchPath { query = "peanut butter" }
                    |> Expect.equal "/api/foods/search?q=peanut%20butter"
        , test "decodes admin user list" <|
            \_ ->
                Decode.decodeString User.listUsersDecoder "{ \"users\": [{ \"id\": \"u1\", \"username\": \"alice\", \"display_name\": \"Alice\", \"status\": \"active\", \"created_at\": \"now\" }] }"
                    |> Result.map List.length
                    |> Expect.equal (Ok 1)
        ]
