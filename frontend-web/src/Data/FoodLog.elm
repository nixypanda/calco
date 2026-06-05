module Data.FoodLog exposing
    ( FoodLog
    , LogItem
    , decoder
    , listDecoder
    )

import Data.Nutrition as Nutrition exposing (NutrientAmount, NutritionSummary)
import Data.Quantity as Quantity exposing (Quantity)
import Json.Decode as Decode exposing (Decoder)
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json


type alias FoodLog =
    { id : String
    , logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe String
    , item : LogItem
    , quantity : Quantity
    , nutritionSummary : NutritionSummary
    , nutrients : List NutrientAmount
    , notes : Maybe String
    }


type alias LogItem =
    { itemType : String
    , id : String
    , name : String
    , brand : Maybe String
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
        (Decode.field "nutrition_summary" Nutrition.summaryDecoder)
        (Decode.field "nutrients" (Decode.list Nutrition.decoder))
        |> Json.andMap (Decode.field "notes" (Decode.nullable Decode.string))


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
