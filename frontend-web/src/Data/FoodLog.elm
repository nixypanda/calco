module Data.FoodLog exposing
    ( FoodLog
    , LogItem
    , decoder
    , listDecoder
    , logItemDecoder
    , logsForDate
    , logsForSlot
    )

import Data.ItemRef as ItemRef exposing (ItemType)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json


type alias FoodLog =
    { id : String
    , logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe MealSlot
    , item : LogItem
    , quantity : Nutrition.Quantity
    , nutrients : List NutrientAmount
    , notes : Maybe String
    }


type alias LogItem =
    { itemType : ItemType
    , id : String
    , name : String
    , brand : Maybe String
    }


decoder : Decoder FoodLog
decoder =
    Decode.map7 FoodLog
        (Decode.field "id" Decode.string)
        (Decode.field "log_date" LocalDate.decoder)
        (Decode.field "device_timezone" (Decode.nullable Decode.string))
        (Decode.field "meal_slot" mealSlotFieldDecoder)
        (Decode.field "item" logItemDecoder)
        (Decode.field "quantity" Nutrition.quantityDecoder)
        (Decode.field "nutrients" (Decode.list Nutrition.decoder))
        |> Json.andMap (Decode.field "notes" (Decode.nullable Decode.string))


mealSlotFieldDecoder : Decoder (Maybe MealSlot)
mealSlotFieldDecoder =
    Decode.nullable Decode.string
        |> Decode.map (Maybe.andThen MealSlot.fromString)


logItemDecoder : Decoder LogItem
logItemDecoder =
    Decode.map4 LogItem
        (Decode.field "type" ItemRef.itemTypeDecoder)
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


logsForDate : LocalDate -> List FoodLog -> List FoodLog
logsForDate date logs =
    List.filter (\log -> LocalDate.equals log.logDate date) logs


logsForSlot : Maybe MealSlot -> List FoodLog -> List FoodLog
logsForSlot slot logs =
    List.filter (\log -> log.mealSlot == slot) logs
