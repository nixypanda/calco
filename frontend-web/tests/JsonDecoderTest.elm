module JsonDecoderTest exposing (tests)

import Api.Foods as Foods
import Api.Logs as Logs
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
                Decode.decodeString Auth.loginSessionDecoder loginSessionJson
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
                Decode.decodeString Foods.searchResponseDecoder searchResponseJson
                    |> Result.map (.items >> List.map .name)
                    |> Expect.equal (Ok [ "Apple" ])
        , test "decodes category suggestions" <|
            \_ ->
                Decode.decodeString Foods.categorySuggestionResponseDecoder categorySuggestionJson
                    |> Result.map (.items >> List.map .value)
                    |> Expect.equal (Ok [ "food and beverages" ])
        , test "decodes product detail" <|
            \_ ->
                Decode.decodeString Foods.productDetailDecoder productDetailJson
                    |> Result.map
                        (\food ->
                            ( food.name
                            , List.length food.nutrients
                            , List.length food.allowedUnits
                            )
                        )
                    |> Expect.equal (Ok ( "Apple", 1, 1 ))
        , test "decodes unit list" <|
            \_ ->
                Decode.decodeString Foods.unitListResponseDecoder unitListJson
                    |> Result.map (.items >> List.map .code)
                    |> Expect.equal (Ok [ "g" ])
        , test "builds food search path with encoded query" <|
            \_ ->
                Foods.searchPath { query = "peanut butter" }
                    |> Expect.equal "/api/foods/search?q=peanut%20butter"
        , test "builds category suggestion path with encoded query and limit" <|
            \_ ->
                Foods.categorySuggestionPath { query = "food and", limit = 8 }
                    |> Expect.equal "/api/foods/categories?q=food%20and&limit=8"
        , test "encodes create product log request without meal slot" <|
            \_ ->
                Logs.createLogRequestEncoder
                    { loggedAt = "2026-06-04T10:00:00+05:30"
                    , mealSlot = Nothing
                    , item = { itemType = "product", id = "food-1" }
                    , quantity = { amount = "1", unit = "g" }
                    , notes = Nothing
                    }
                    |> Encode.encode 0
                    |> Decode.decodeString Decode.value
                    |> Expect.equal (Decode.decodeString Decode.value createLogWithoutMealSlotJson)
        , test "encodes create product log request with meal slot and notes" <|
            \_ ->
                Logs.createLogRequestEncoder
                    { loggedAt = "2026-06-04T10:00:00+05:30"
                    , mealSlot = Just "lunch"
                    , item = { itemType = "product", id = "food-1" }
                    , quantity = { amount = "1", unit = "g" }
                    , notes = Just "Ate after run"
                    }
                    |> Encode.encode 0
                    |> Decode.decodeString Decode.value
                    |> Expect.equal (Decode.decodeString Decode.value createLogWithMealSlotJson)
        , test "encodes update log request with null meal slot and notes" <|
            \_ ->
                Logs.updateLogRequestEncoder
                    { mealSlot = Nothing
                    , quantity = { amount = "2", unit = "g" }
                    , notes = Nothing
                    }
                    |> Encode.encode 0
                    |> Decode.decodeString Decode.value
                    |> Expect.equal (Decode.decodeString Decode.value updateLogJson)
        , test "decodes admin user list" <|
            \_ ->
                Decode.decodeString User.listUsersDecoder userListJson
                    |> Result.map List.length
                    |> Expect.equal (Ok 1)
        ]


loginSessionJson : String
loginSessionJson =
    """
    { "identity": { "id": "1", "username": "admin", "role": "admin" }
    , "profile": null
    }
    """


searchResponseJson : String
searchResponseJson =
    """
    { "items":
        [{ "id": "f1"
         , "source": "USER"
         , "source_id": null
         , "barcode": "123"
         , "name": "Apple"
         , "brand": null
         , "categories": ["fruit"]
         , "serving_size_g": "100"
         , "energy_kcal_per_100g": "52"
         , "energy_kcal_per_serving": null
         }]
    }
    """


categorySuggestionJson : String
categorySuggestionJson =
    """
    { "items":
        [ { "value": "food and beverages", "count": 4 } ]
    }
    """


productDetailJson : String
productDetailJson =
    """
    { "id": "f1"
    , "source": "USER"
    , "source_id": null
    , "visibility": "private"
    , "barcode": null
    , "name": "Apple"
    , "brand": "Local"
    , "categories": ["fruit"]
    , "default_quantity": "1"
    , "default_unit": "g"
    , "serving_size_g": "100"
    , "nutrients":
        [{ "code": "ENERGY_KCAL"
         , "amount_per_100g": "52"
         , "unit": "kcal"
         , "source": null
         , "confidence": null
         }]
    , "servings":
        [{ "label": "Small"
         , "quantity": "1"
         , "unit": "piece"
         , "grams": "100"
         }]
    , "allowed_units":
        [{ "code": "g"
         , "name": "Gram"
         , "kind": "mass"
         }]
    }
    """


unitListJson : String
unitListJson =
    """
    { "items": [{ "code": "g", "name": "Gram", "kind": "mass" }] }
    """


createLogWithoutMealSlotJson : String
createLogWithoutMealSlotJson =
    """
    { "logged_at": "2026-06-04T10:00:00+05:30"
    , "item": { "type": "product", "id": "food-1" }
    , "quantity": { "amount": "1", "unit": "g" }
    , "notes": null
    }
    """


createLogWithMealSlotJson : String
createLogWithMealSlotJson =
    """
    { "logged_at": "2026-06-04T10:00:00+05:30"
    , "item": { "type": "product", "id": "food-1" }
    , "quantity": { "amount": "1", "unit": "g" }
    , "notes": "Ate after run"
    , "meal_slot": "lunch"
    }
    """


updateLogJson : String
updateLogJson =
    """
    { "quantity": { "amount": "2", "unit": "g" }
    , "meal_slot": null
    , "notes": null
    }
    """


userListJson : String
userListJson =
    """
    { "users":
        [{ "id": "u1"
         , "username": "alice"
         , "display_name": "Alice"
         , "status": "active"
         , "created_at": "now"
         }]
    }
    """
