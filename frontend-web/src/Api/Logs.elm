module Api.Logs exposing
    ( BatchLogResponse
    , CreateAdHocLogRequest
    , CreateLogRequest
    , LastUsedItemsRequest
    , LatestSlotResponse
    , LatestSlotsResponse
    , QuantityUsage
    , RecentItem
    , RecentItemsRequest
    , RecentItemsResponse
    , SummaryRequest
    , UpdateLogRequest
    , createAdHocLog
    , createAdHocLogRequestEncoder
    , createLog
    , createLogRequestEncoder
    , createLogsBatch
    , deleteLog
    , getLog
    , lastUsedItems
    , latestSlots
    , listLogs
    , recentItems
    , summary
    , updateLog
    , updateLogRequestEncoder
    )

import Api.Client as Client
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.LogSummary as LogSummary exposing (DaySummary)
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json
import Url.Builder as Builder


type alias CreateLogRequest =
    { logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe MealSlot
    , item : ItemRef
    , quantity : Nutrition.Quantity
    , notes : Maybe String
    }


type alias CreateAdHocLogRequest =
    { logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe MealSlot
    , name : String
    , brand : Maybe String
    , quantity : Nutrition.Quantity
    , nutrients : List Nutrition.NutrientAmount
    , notes : Maybe String
    }


type alias UpdateLogRequest =
    { mealSlot : Maybe MealSlot, quantity : Nutrition.Quantity, notes : Maybe String }


type alias LatestSlotResponse =
    { sourceDate : LocalDate, mealSlot : Maybe MealSlot, items : List FoodLog }


type alias LatestSlotsResponse =
    { slots : List LatestSlotResponse }


type alias RecentItem =
    { item : FoodLog.LogItem
    , lastUsedDate : LocalDate
    , mealSlot : Maybe MealSlot
    , quantity : Nutrition.Quantity
    , nutritionSummary : Nutrition.NutritionSummary
    , topQuantities : List QuantityUsage
    }


type alias QuantityUsage =
    { quantity : Nutrition.Quantity, logCount : Int }


type alias RecentItemsResponse =
    { items : List RecentItem }


type alias RecentItemsRequest =
    { fromDate : LocalDate, toDate : LocalDate, mealSlot : Maybe MealSlot }


type alias SummaryRequest =
    { fromDate : LocalDate, toDate : LocalDate }


type alias LastUsedItemsRequest =
    { fromDate : LocalDate, toDate : LocalDate, mealSlot : Maybe MealSlot, items : List ItemRef }


type alias BatchLogResponse =
    { items : List FoodLog }


createLog : CreateLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
createLog request toMsg =
    Client.post (Builder.absolute [ "api", "logs" ] [])
        (createLogRequestEncoder request)
        FoodLog.decoder
        toMsg


createAdHocLog : CreateAdHocLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
createAdHocLog request toMsg =
    Client.post (Builder.absolute [ "api", "logs", "ad-hoc" ] [])
        (createAdHocLogRequestEncoder request)
        FoodLog.decoder
        toMsg


createLogsBatch :
    List CreateLogRequest
    -> (Result Client.ApiError BatchLogResponse -> msg)
    -> Cmd msg
createLogsBatch requests toMsg =
    Client.post (Builder.absolute [ "api", "logs", "batch" ] [])
        (Encode.object [ ( "items", Encode.list createLogRequestEncoder requests ) ])
        batchLogResponseDecoder
        toMsg


getLog : String -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
getLog id toMsg =
    Client.get (Builder.absolute [ "api", "logs", id ] []) FoodLog.decoder toMsg


updateLog : String -> UpdateLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
updateLog id request toMsg =
    Client.put (Builder.absolute [ "api", "logs", id ] [])
        (updateLogRequestEncoder request)
        FoodLog.decoder
        toMsg


deleteLog : String -> (Result Client.ApiError () -> msg) -> Cmd msg
deleteLog id toMsg =
    Client.delete (Builder.absolute [ "api", "logs", id ] []) toMsg


latestSlots :
    { before : LocalDate, lookbackDays : Int }
    -> (Result Client.ApiError LatestSlotsResponse -> msg)
    -> Cmd msg
latestSlots query toMsg =
    Client.get
        (Builder.absolute [ "api", "logs", "latest-slots" ]
            [ Builder.string "before" (LocalDate.format query.before)
            , Builder.int "lookback_days" query.lookbackDays
            ]
        )
        latestSlotsResponseDecoder
        toMsg


recentItems : RecentItemsRequest -> (Result Client.ApiError RecentItemsResponse -> msg) -> Cmd msg
recentItems request toMsg =
    Client.get
        (Builder.absolute [ "api", "logs", "recent-items" ]
            ([ Builder.string "from_date" (LocalDate.format request.fromDate)
             , Builder.string "to_date" (LocalDate.format request.toDate)
             ]
                ++ maybeMealSlotQuery request.mealSlot
            )
        )
        recentItemsResponseDecoder
        toMsg


summary : SummaryRequest -> (Result Client.ApiError (List DaySummary) -> msg) -> Cmd msg
summary request toMsg =
    Client.get
        (Builder.absolute [ "api", "logs", "summary" ]
            [ Builder.string "from_date" (LocalDate.format request.fromDate)
            , Builder.string "to_date" (LocalDate.format request.toDate)
            ]
        )
        LogSummary.listDecoder
        toMsg


lastUsedItems :
    LastUsedItemsRequest
    -> (Result Client.ApiError RecentItemsResponse -> msg)
    -> Cmd msg
lastUsedItems request toMsg =
    Client.post (Builder.absolute [ "api", "logs", "last-used" ] [])
        (Encode.object
            [ ( "from_date", Encode.string (LocalDate.format request.fromDate) )
            , ( "to_date", Encode.string (LocalDate.format request.toDate) )
            , ( "meal_slot", Json.maybe (Encode.string << MealSlot.toString) request.mealSlot )
            , ( "items", Encode.list ItemRef.encoder request.items )
            ]
        )
        recentItemsResponseDecoder
        toMsg


listLogs : LocalDate -> (Result Client.ApiError (List FoodLog) -> msg) -> Cmd msg
listLogs date toMsg =
    Client.get
        (Builder.absolute [ "api", "logs" ] [ Builder.string "log_date" (LocalDate.format date) ])
        FoodLog.listDecoder
        toMsg


createLogRequestEncoder : CreateLogRequest -> Encode.Value
createLogRequestEncoder request =
    Encode.object
        (baseLogFields request
            ++ mealSlotField request.mealSlot
            ++ deviceTimezoneField request.deviceTimezone
        )


createAdHocLogRequestEncoder : CreateAdHocLogRequest -> Encode.Value
createAdHocLogRequestEncoder request =
    Encode.object
        ([ ( "log_date", Encode.string (LocalDate.format request.logDate) )
         , ( "name", Encode.string request.name )
         , ( "brand", Json.maybe Encode.string request.brand )
         , ( "quantity", Nutrition.quantityEncoder request.quantity )
         , ( "nutrients", Encode.list nutrientSnapshotEncoder request.nutrients )
         , ( "notes", Json.maybe Encode.string request.notes )
         ]
            ++ mealSlotField request.mealSlot
            ++ deviceTimezoneField request.deviceTimezone
        )


nutrientSnapshotEncoder : Nutrition.NutrientAmount -> Encode.Value
nutrientSnapshotEncoder nutrient =
    Encode.object
        [ ( "code", Encode.string nutrient.code )
        , ( "amount", Encode.string nutrient.amount )
        , ( "unit", Encode.string nutrient.unit )
        ]


updateLogRequestEncoder : UpdateLogRequest -> Encode.Value
updateLogRequestEncoder request =
    Encode.object
        [ ( "quantity", Nutrition.quantityEncoder request.quantity )
        , ( "meal_slot", Json.maybe (Encode.string << MealSlot.toString) request.mealSlot )
        , ( "notes", Json.maybe Encode.string request.notes )
        ]


baseLogFields : CreateLogRequest -> List ( String, Encode.Value )
baseLogFields request =
    [ ( "log_date", Encode.string (LocalDate.format request.logDate) )
    , ( "item", ItemRef.encoder request.item )
    , ( "quantity", Nutrition.quantityEncoder request.quantity )
    , ( "notes", Json.maybe Encode.string request.notes )
    ]


mealSlotField : Maybe MealSlot -> List ( String, Encode.Value )
mealSlotField maybeSlot =
    case maybeSlot of
        Just slot ->
            [ ( "meal_slot", Encode.string (MealSlot.toString slot) ) ]

        Nothing ->
            []


deviceTimezoneField : Maybe String -> List ( String, Encode.Value )
deviceTimezoneField maybeTimezone =
    case maybeTimezone of
        Just tz ->
            [ ( "device_timezone", Encode.string tz ) ]

        Nothing ->
            []


latestSlotsResponseDecoder : Decode.Decoder LatestSlotsResponse
latestSlotsResponseDecoder =
    Decode.map LatestSlotsResponse (Decode.field "slots" (Decode.list latestSlotResponseDecoder))


latestSlotResponseDecoder : Decode.Decoder LatestSlotResponse
latestSlotResponseDecoder =
    Decode.map3 LatestSlotResponse
        (Decode.field "source_date" LocalDate.decoder)
        (Decode.field "meal_slot" Decode.string |> Decode.map MealSlot.fromString)
        (Decode.field "items" (Decode.list FoodLog.decoder))


batchLogResponseDecoder : Decode.Decoder BatchLogResponse
batchLogResponseDecoder =
    Decode.map BatchLogResponse (Decode.field "items" (Decode.list FoodLog.decoder))


recentItemsResponseDecoder : Decode.Decoder RecentItemsResponse
recentItemsResponseDecoder =
    Decode.map RecentItemsResponse (Decode.field "items" (Decode.list recentItemDecoder))


recentItemDecoder : Decode.Decoder RecentItem
recentItemDecoder =
    Decode.map6 RecentItem
        (Decode.field "item" FoodLog.logItemDecoder)
        (Decode.field "last_used_date" LocalDate.decoder)
        (Decode.field "meal_slot" (Decode.nullable Decode.string)
            |> Decode.map (Maybe.andThen MealSlot.fromString)
        )
        (Decode.field "quantity" Nutrition.quantityDecoder)
        (Decode.field "nutrition_summary" Nutrition.summaryDecoder)
        (Decode.field "top_quantities" (Decode.list quantityUsageDecoder))


quantityUsageDecoder : Decode.Decoder QuantityUsage
quantityUsageDecoder =
    Decode.map2 QuantityUsage
        (Decode.field "quantity" Nutrition.quantityDecoder)
        (Decode.field "log_count" Decode.int)


maybeMealSlotQuery : Maybe MealSlot -> List Builder.QueryParameter
maybeMealSlotQuery maybeSlot =
    case maybeSlot of
        Just slot ->
            [ Builder.string "meal_slot" (MealSlot.toString slot) ]

        Nothing ->
            []
