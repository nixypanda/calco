module Data.FoodLog exposing
    ( FoodLog
    , GroupedLogs
    , SummaryResponse
    , decoder
    , groupLogs
    , listDecoder
    , logsForSlot
    , summaryDecoder
    )

import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Quantity as Quantity exposing (Quantity)
import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)


type alias FoodLog =
    { id : String
    , loggedAt : String
    , mealSlot : Maybe String
    , item : ItemRef
    , quantity : Quantity
    , nutrients : List NutrientAmount
    , notes : Maybe String
    }


type alias GroupedLogs =
    { breakfast : List FoodLog
    , lunch : List FoodLog
    , dinner : List FoodLog
    , snack : List FoodLog
    , other : List FoodLog
    }


type alias SummaryResponse =
    { from : LocalDate
    , to : LocalDate
    , totals : List NutrientAmount
    }


decoder : Decoder FoodLog
decoder =
    Decode.map7 FoodLog
        (Decode.field "id" Decode.string)
        (Decode.field "logged_at" Decode.string)
        (Decode.field "meal_slot" (Decode.nullable Decode.string))
        (Decode.field "item" ItemRef.decoder)
        (Decode.field "quantity" Quantity.decoder)
        (Decode.field "nutrients" (Decode.list Nutrition.decoder))
        (Decode.field "notes" (Decode.nullable Decode.string))


listDecoder : Decoder (List FoodLog)
listDecoder =
    Decode.field "items" (Decode.list decoder)


summaryDecoder : Decoder SummaryResponse
summaryDecoder =
    Decode.map3 SummaryResponse
        (Decode.field "from" localDateDecoder)
        (Decode.field "to" localDateDecoder)
        (Decode.field "totals" (Decode.list Nutrition.decoder))


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


localDateDecoder : Decoder LocalDate
localDateDecoder =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case LocalDate.fromString raw of
                    Just date ->
                        Decode.succeed date

                    Nothing ->
                        Decode.fail ("Invalid local date: " ++ raw)
            )
