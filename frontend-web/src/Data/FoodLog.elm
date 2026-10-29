module Data.FoodLog exposing
    ( AdHocSnapshot
    , FoodLog
    , LogItem(..)
    , MealSnapshot
    , ProductSnapshot
    , decoder
    , itemBrand
    , itemName
    , itemRef
    , listDecoder
    , logItemDecoder
    , logsForDate
    , logsForSlot
    )

import Data.ItemRef exposing (ItemRef, ItemType(..))
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


type LogItem
    = ProductLogItem ProductSnapshot
    | MealLogItem MealSnapshot
    | AdHocLogItem AdHocSnapshot


type alias ProductSnapshot =
    { id : String, name : String, brand : Maybe String }


type alias MealSnapshot =
    { id : String, name : String }


type alias AdHocSnapshot =
    { name : String, brand : Maybe String }


itemName : LogItem -> String
itemName item =
    case item of
        ProductLogItem product ->
            product.name

        MealLogItem meal ->
            meal.name

        AdHocLogItem adHoc ->
            adHoc.name


itemBrand : LogItem -> Maybe String
itemBrand item =
    case item of
        ProductLogItem product ->
            product.brand

        MealLogItem _ ->
            Nothing

        AdHocLogItem adHoc ->
            adHoc.brand


itemRef : LogItem -> Maybe ItemRef
itemRef item =
    case item of
        ProductLogItem product ->
            Just { itemType = Product, id = product.id }

        MealLogItem meal ->
            Just { itemType = Meal, id = meal.id }

        AdHocLogItem _ ->
            Nothing


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
    Decode.nullable Decode.string |> Decode.map (Maybe.andThen MealSlot.fromString)


logItemDecoder : Decoder LogItem
logItemDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\itemType ->
                case itemType of
                    "product" ->
                        Decode.map3
                            (\id name brand ->
                                ProductLogItem { id = id, name = name, brand = brand }
                            )
                            (Decode.field "id" Decode.string)
                            (Decode.field "name" Decode.string)
                            optionalBrandDecoder

                    "meal" ->
                        Decode.map2 (\id name -> MealLogItem { id = id, name = name })
                            (Decode.field "id" Decode.string)
                            (Decode.field "name" Decode.string)

                    "ad_hoc" ->
                        Decode.map2 (\name brand -> AdHocLogItem { name = name, brand = brand })
                            (Decode.field "name" Decode.string)
                            optionalBrandDecoder

                    _ ->
                        Decode.fail ("unknown food log item type: " ++ itemType)
            )


optionalBrandDecoder : Decoder (Maybe String)
optionalBrandDecoder =
    Decode.oneOf [ Decode.field "brand" (Decode.nullable Decode.string), Decode.succeed Nothing ]


listDecoder : Decoder (List FoodLog)
listDecoder =
    Decode.field "items" (Decode.list decoder)


logsForDate : LocalDate -> List FoodLog -> List FoodLog
logsForDate date logs =
    List.filter (\log -> LocalDate.equals log.logDate date) logs


logsForSlot : Maybe MealSlot -> List FoodLog -> List FoodLog
logsForSlot slot logs =
    List.filter (\log -> log.mealSlot == slot) logs
