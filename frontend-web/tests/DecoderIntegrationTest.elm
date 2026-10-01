module DecoderIntegrationTest exposing (tests)

import Api.Foods as Foods
import Api.Logs as Logs
import Data.Auth as Auth
import Data.FoodLog as FoodLog
import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.User as User
import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Test exposing (Test, describe, fuzz, test)


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
                Decode.decodeString Nutrition.quantityDecoder
                    "{ \"amount\": \"1.5\", \"unit\": \"g\" }"
                    |> Expect.equal (Ok { amount = "1.5", unit = "g" })
        , fuzz quantityFuzzer "quantity encoder and decoder round trip" <|
            \quantity ->
                quantity
                    |> Nutrition.quantityEncoder
                    |> Encode.encode 0
                    |> Decode.decodeString Nutrition.quantityDecoder
                    |> Expect.equal (Ok quantity)
        , test "decodes item ref" <|
            \_ ->
                Decode.decodeString ItemRef.decoder "{ \"type\": \"product\", \"id\": \"p1\" }"
                    |> Expect.equal (Ok { itemType = ItemRef.Product, id = "p1" })
        , fuzz itemRefFuzzer "item ref encoder and decoder round trip" <|
            \item ->
                item
                    |> ItemRef.encoder
                    |> Encode.encode 0
                    |> Decode.decodeString ItemRef.decoder
                    |> Expect.equal (Ok item)
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
        , test "decodes Open Food Facts barcode lookup metadata" <|
            \_ ->
                Decode.decodeString Foods.barcodeLookupResponseDecoder barcodeLookupJson
                    |> Result.map
                        (\response ->
                            ( response.product.name
                            , response.lookup.origin
                            , response.lookup.note
                            )
                        )
                    |> Expect.equal
                        (Ok
                            ( "Apple"
                            , Foods.OpenFoodFacts
                            , Just
                                "Food was not found locally and was imported from Open Food Facts."
                            )
                        )
        , test "decodes unit list" <|
            \_ ->
                Decode.decodeString Foods.unitListResponseDecoder unitListJson
                    |> Result.map (.items >> List.map .code)
                    |> Expect.equal (Ok [ "g" ])
        , test "builds food search path with encoded query" <|
            \_ ->
                Foods.searchPath { query = "peanut butter", scope = Foods.SearchAll }
                    |> Expect.equal "/api/foods/search?q=peanut%20butter&scope=all"
        , test "builds barcode lookup path" <|
            \_ ->
                Foods.barcodePath "890 123"
                    |> Expect.equal "/api/foods/barcode/890%20123"
        , test "builds category suggestion path with encoded query and limit" <|
            \_ ->
                Foods.categorySuggestionPath { query = "food and", limit = 8 }
                    |> Expect.equal "/api/foods/categories?q=food%20and&limit=8"
        , test "encodes create product log request without meal slot" <|
            \_ ->
                Logs.createLogRequestEncoder
                    { logDate = date "2026-06-04"
                    , deviceTimezone = Just "Asia/Kolkata"
                    , mealSlot = Nothing
                    , item = { itemType = ItemRef.Product, id = "food-1" }
                    , quantity = { amount = "1", unit = "g" }
                    , notes = Nothing
                    }
                    |> Encode.encode 0
                    |> Decode.decodeString Decode.value
                    |> Expect.equal (Decode.decodeString Decode.value createLogWithoutMealSlotJson)
        , test "encodes create product log request with meal slot and notes" <|
            \_ ->
                Logs.createLogRequestEncoder
                    { logDate = date "2026-06-04"
                    , deviceTimezone = Just "Asia/Kolkata"
                    , mealSlot = Just Lunch
                    , item = { itemType = ItemRef.Product, id = "food-1" }
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
        , test "decodes food log item identity" <|
            \_ ->
                Decode.decodeString FoodLog.decoder foodLogJson
                    |> Result.map
                        (\log ->
                            ( FoodLog.itemRef log.item
                            , FoodLog.itemName log.item
                            , FoodLog.itemBrand log.item
                            )
                        )
                    |> Expect.equal
                        (Ok
                            ( Just { itemType = ItemRef.Product, id = "food-1" }
                            , "Apple"
                            , Just "Local"
                            )
                        )
        , test "decodes recent items with serving nutrition" <|
            \_ ->
                Decode.decodeString Logs.recentItemsResponseDecoder recentItemsJson
                    |> Result.map
                        (.items
                            >> List.map
                                (\item ->
                                    ( item.quantity.amount
                                    , item.quantity.unit
                                    , item.nutritionSummary.energyKcal
                                    )
                                )
                        )
                    |> Expect.equal (Ok [ ( "175", "g", Just "91" ) ])
        , test "decodes recent item top quantities" <|
            \_ ->
                Decode.decodeString Logs.recentItemsResponseDecoder recentItemsJson
                    |> Result.map
                        (.items
                            >> List.concatMap .topQuantities
                            >> List.map
                                (\usage -> ( usage.quantity.amount, usage.logCount ))
                        )
                    |> Expect.equal (Ok [ ( "175", 4 ), ( "100", 1 ) ])
        , test "decodes batched latest slots" <|
            \_ ->
                Decode.decodeString Logs.latestSlotsResponseDecoder latestSlotsJson
                    |> Result.map
                        (.slots
                            >> List.map
                                (\slot ->
                                    ( LocalDate.format slot.sourceDate
                                    , slot.mealSlot
                                    , List.map .id slot.items
                                    )
                                )
                        )
                    |> Expect.equal
                        (Ok
                            [ ( "2026-06-03", "breakfast", [ "log-1" ] )
                            , ( "2026-06-01", "late_night_snack", [ "log-1" ] )
                            ]
                        )
        , test "decodes empty latest slots response" <|
            \_ ->
                Decode.decodeString Logs.latestSlotsResponseDecoder """{ "slots": [] }"""
                    |> Result.map .slots
                    |> Expect.equal (Ok [])
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
         , "nutrition_summary":
            { "per_100g":
                { "energy_kcal": "52"
                , "protein_g": null
                , "carbs_g": null
                , "fat_g": null
                , "fiber_g": null
                }
            }
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
    , "nutrition_summary":
        { "per_100g":
            { "energy_kcal": "52"
            , "protein_g": null
            , "carbs_g": null
            , "fat_g": null
            , "fiber_g": null
            }
        }
    , "nutrients":
        [{ "code": "ENERGY_KCAL"
         , "amount_per_100g": "52"
         , "unit": "kcal"
         , "source": null
         , "confidence": null
         }]
    , "servings":
        [{ "unit": "piece"
         , "grams_per_unit": "100"
         }]
    , "allowed_units":
        [{ "code": "g"
         , "name": "Gram"
         , "kind": "mass"
         }]
    }
    """


barcodeLookupJson : String
barcodeLookupJson =
    String.dropRight 1 (String.trim productDetailJson)
        ++ ", \"lookup\": { \"origin\": \"open_food_facts\", \"note\": "
        ++ "\"Food was not found locally and was imported from Open Food Facts.\" } }"


unitListJson : String
unitListJson =
    """
    { "items": [{ "code": "g", "name": "Gram", "kind": "mass" }] }
    """


createLogWithoutMealSlotJson : String
createLogWithoutMealSlotJson =
    """
    { "log_date": "2026-06-04"
    , "device_timezone": "Asia/Kolkata"
    , "item": { "type": "product", "id": "food-1" }
    , "quantity": { "amount": "1", "unit": "g" }
    , "notes": null
    }
    """


createLogWithMealSlotJson : String
createLogWithMealSlotJson =
    """
    { "log_date": "2026-06-04"
    , "device_timezone": "Asia/Kolkata"
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


foodLogJson : String
foodLogJson =
    """
    { "id": "log-1"
    , "log_date": "2026-06-04"
    , "device_timezone": "Asia/Kolkata"
    , "meal_slot": "lunch"
    , "item":
        { "type": "product"
        , "id": "food-1"
        , "name": "Apple"
        , "brand": "Local"
        }
    , "quantity": { "amount": "2", "unit": "serving" }
    , "nutrition_summary":
        { "energy_kcal": "104"
        , "protein_g": null
        , "carbs_g": null
        , "fat_g": null
        , "fiber_g": null
        }
    , "nutrients":
        [{ "code": "ENERGY_KCAL"
         , "amount": "104"
         , "unit": "kcal"
         }]
    , "notes": null
    , "created_at": "2026-06-04T10:00:00+05:30"
    , "updated_at": "2026-06-04T10:00:00+05:30"
    }
    """


recentItemsJson : String
recentItemsJson =
    """
    { "items":
        [{ "item":
            { "type": "product"
            , "id": "food-1"
            , "name": "Apple"
            , "brand": "Local"
            }
         , "last_used_date": "2026-06-03"
         , "meal_slot": "breakfast"
         , "quantity": { "amount": "175", "unit": "g" }
         , "nutrition_summary":
            { "energy_kcal": "91"
            , "protein_g": null
            , "carbs_g": null
            , "fat_g": null
            , "fiber_g": null
            }
         , "top_quantities":
            [ { "quantity": { "amount": "175", "unit": "g" }, "log_count": 4 }
            , { "quantity": { "amount": "100", "unit": "g" }, "log_count": 1 }
            ]
         }]
    }
    """


latestSlotsJson : String
latestSlotsJson =
    """
    { "slots":
        [ { "source_date": "2026-06-03"
          , "meal_slot": "breakfast"
          , "items": [ """
        ++ foodLogJson
        ++ """ ]
          }
        , { "source_date": "2026-06-01"
          , "meal_slot": "late_night_snack"
          , "items": [ """
        ++ foodLogJson
        ++ """ ]
          }
        ]
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


today : LocalDate
today =
    date "2026-06-04"


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            case LocalDate.fromParts 1970 1 1 of
                Just fallback ->
                    fallback

                Nothing ->
                    -- Unreachable: 1970-01-01 is always valid.
                    today


itemRefFuzzer : Fuzzer ItemRef
itemRefFuzzer =
    Fuzz.map2 ItemRef.ItemRef itemTypeFuzzer Fuzz.string


itemTypeFuzzer : Fuzzer ItemRef.ItemType
itemTypeFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant ItemRef.Product
        , Fuzz.constant ItemRef.Meal
        ]


quantityFuzzer : Fuzzer Nutrition.Quantity
quantityFuzzer =
    Fuzz.map2 Nutrition.Quantity Fuzz.string Fuzz.string
