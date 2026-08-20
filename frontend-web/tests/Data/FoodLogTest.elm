module Data.FoodLogTest exposing (tests)

import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Json.Decode as Decode
import Lib.Date as LocalDate exposing (LocalDate)
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Data.FoodLog"
        [ describe "logsForSlot"
            [ test "keeps only logs saved in the requested slot" <|
                \_ ->
                    FoodLog.logsForSlot (Just Lunch) allLogs
                        |> List.map .id
                        |> Expect.equal [ "lunch-1" ]
            , test "the unslotted bucket collects logs saved without a slot" <|
                \_ ->
                    FoodLog.logsForSlot Nothing allLogs
                        |> List.map .id
                        |> Expect.equal [ "unslotted-1" ]
            ]
        , describe "decoder"
            [ test "reads a known meal slot" <|
                \_ ->
                    decodeSlot "\"dinner\""
                        |> Expect.equal (Ok (Just Dinner))
            , test "a null meal slot lands in the unslotted bucket" <|
                \_ ->
                    decodeSlot "null"
                        |> Expect.equal (Ok Nothing)
            , test "a slot the client cannot represent lands in the unslotted bucket" <|
                \_ ->
                    decodeSlot "\"brunch\""
                        |> Expect.equal (Ok Nothing)
            ]
        ]


decodeSlot : String -> Result Decode.Error (Maybe MealSlot)
decodeSlot rawSlot =
    Decode.decodeString FoodLog.decoder (logJson rawSlot)
        |> Result.map .mealSlot


logJson : String -> String
logJson rawSlot =
    """
    { "id": "log-1"
    , "log_date": "2026-05-30"
    , "device_timezone": null
    , "meal_slot": """
        ++ rawSlot
        ++ """
    , "item": { "type": "product", "id": "food-1", "name": "Apple", "brand": null }
    , "quantity": { "amount": "100", "unit": "g" }
    , "nutrients": []
    , "notes": null
    }
    """


allLogs : List FoodLog
allLogs =
    [ log "lunch-1" (Just Lunch)
    , log "breakfast-1" (Just Breakfast)
    , log "unslotted-1" Nothing
    ]


log : String -> Maybe MealSlot -> FoodLog
log id mealSlot =
    { id = id
    , logDate = date
    , deviceTimezone = Nothing
    , mealSlot = mealSlot
    , item =
        { itemType = ItemRef.Product
        , id = "food-1"
        , name = "Apple"
        , brand = Nothing
        }
    , quantity = { amount = "100", unit = "g" }
    , nutrients = []
    , notes = Nothing
    }


date : LocalDate
date =
    case LocalDate.fromString "2026-05-30" of
        Just value ->
            value

        Nothing ->
            LocalDate.fromPosix Time.utc (Time.millisToPosix 0)
