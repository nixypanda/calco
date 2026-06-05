module Data.FoodLog exposing
    ( FoodLog
    , GroupedLogs
    , LogItem
    , decoder
    , groupLogs
    , listDecoder
    , logsForSlot
    )

import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Quantity as Quantity exposing (Quantity)
import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)


type alias FoodLog =
    { id : String
    , logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe String
    , item : LogItem
    , quantity : Quantity
    , nutrients : List NutrientAmount
    , notes : Maybe String
    }


type alias LogItem =
    { itemType : String
    , id : String
    , name : String
    , brand : Maybe String
    }


type alias GroupedLogs =
    { breakfast : List FoodLog
    , lunch : List FoodLog
    , dinner : List FoodLog
    , snack : List FoodLog
    , other : List FoodLog
    }


decoder : Decoder FoodLog
decoder =
    Decode.map8 FoodLog
        (Decode.field "id" Decode.string)
        (Decode.field "log_date" dateFieldDecoder)
        (Decode.field "device_timezone" (Decode.nullable Decode.string))
        (Decode.field "meal_slot" (Decode.nullable Decode.string))
        (Decode.field "item" logItemDecoder)
        (Decode.field "quantity" Quantity.decoder)
        (Decode.field "nutrients" (Decode.list Nutrition.decoder))
        (Decode.field "notes" (Decode.nullable Decode.string))


dateFieldDecoder : Decoder LocalDate
dateFieldDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case LocalDate.fromString raw of
                    Just date ->
                        Decode.succeed date

                    Nothing ->
                        Decode.fail ("Invalid local date: " ++ raw)
            )


logItemDecoder : Decoder LogItem
logItemDecoder =
    Decode.map4 LogItem
        (Decode.field "type" Decode.string)
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.oneOf
            [ Decode.field "brand" (Decode.nullable Decode.string)
            , Decode.succeed Nothing
            ]
        )


listDecoder : Decoder (List FoodLog)
listDecoder =
    Decode.field "items" (Decode.list decoder)


groupLogs : List FoodLog -> GroupedLogs
groupLogs logs =
    { breakfast = logsForSlot MealSlot.Breakfast logs
    , lunch = logsForSlot MealSlot.Lunch logs
    , dinner = logsForSlot MealSlot.Dinner logs
    , snack = logsForSlot MealSlot.Snack logs
    , other = logsForSlot MealSlot.Other logs
    }


logsForSlot : MealSlot -> List FoodLog -> List FoodLog
logsForSlot slot logs =
    List.filter (\log -> MealSlot.matches slot log.mealSlot) logs
