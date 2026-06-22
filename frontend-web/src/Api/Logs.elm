module Api.Logs exposing
    ( BatchLogResponse
    , CreateLogRequest
    , LatestSlotResponse
    , UpdateLogRequest
    , createLog
    , createLogRequestEncoder
    , createLogsBatch
    , deleteLog
    , getLog
    , latestSlot
    , listLogs
    , updateLog
    , updateLogRequestEncoder
    )

import Api.Client as Client
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.Nutrition as Nutrition
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json
import Url.Builder as Builder


type alias CreateLogRequest =
    { logDate : LocalDate
    , deviceTimezone : Maybe String
    , mealSlot : Maybe String
    , item : ItemRef
    , quantity : Nutrition.Quantity
    , notes : Maybe String
    }


type alias UpdateLogRequest =
    { mealSlot : Maybe String
    , quantity : Nutrition.Quantity
    , notes : Maybe String
    }


type alias LatestSlotResponse =
    { sourceDate : LocalDate
    , mealSlot : String
    , items : List FoodLog
    }


type alias BatchLogResponse =
    { items : List FoodLog
    }


createLog : CreateLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
createLog request toMsg =
    Client.post
        (Builder.absolute [ "api", "logs" ] [])
        (createLogRequestEncoder request)
        FoodLog.decoder
        toMsg


createLogsBatch :
    List CreateLogRequest
    -> (Result Client.ApiError BatchLogResponse -> msg)
    -> Cmd msg
createLogsBatch requests toMsg =
    Client.post
        (Builder.absolute [ "api", "logs", "batch" ] [])
        (Encode.object
            [ ( "items", Encode.list createLogRequestEncoder requests )
            ]
        )
        batchLogResponseDecoder
        toMsg


getLog : String -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
getLog id toMsg =
    Client.get
        (Builder.absolute [ "api", "logs", id ] [])
        FoodLog.decoder
        toMsg


updateLog : String -> UpdateLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
updateLog id request toMsg =
    Client.put
        (Builder.absolute [ "api", "logs", id ] [])
        (updateLogRequestEncoder request)
        FoodLog.decoder
        toMsg


deleteLog : String -> (Result Client.ApiError () -> msg) -> Cmd msg
deleteLog id toMsg =
    Client.delete
        (Builder.absolute [ "api", "logs", id ] [])
        toMsg


latestSlot :
    { mealSlot : String, before : LocalDate, lookbackDays : Int }
    -> (Result Client.ApiError LatestSlotResponse -> msg)
    -> Cmd msg
latestSlot query toMsg =
    Client.get
        (Builder.absolute
            [ "api", "logs", "latest-slot" ]
            [ Builder.string "meal_slot" query.mealSlot
            , Builder.string "before" (LocalDate.format query.before)
            , Builder.int "lookback_days" query.lookbackDays
            ]
        )
        latestSlotResponseDecoder
        toMsg


listLogs : LocalDate -> (Result Client.ApiError (List FoodLog) -> msg) -> Cmd msg
listLogs date toMsg =
    Client.get
        (Builder.absolute
            [ "api", "logs" ]
            [ Builder.string "log_date" (LocalDate.format date)
            ]
        )
        FoodLog.listDecoder
        toMsg


createLogRequestEncoder : CreateLogRequest -> Encode.Value
createLogRequestEncoder request =
    Encode.object
        (baseLogFields request
            ++ mealSlotField request.mealSlot
            ++ deviceTimezoneField request.deviceTimezone
        )


updateLogRequestEncoder : UpdateLogRequest -> Encode.Value
updateLogRequestEncoder request =
    Encode.object
        [ ( "quantity", Nutrition.quantityEncoder request.quantity )
        , ( "meal_slot", Json.maybe Encode.string request.mealSlot )
        , ( "notes", Json.maybe Encode.string request.notes )
        ]


baseLogFields : CreateLogRequest -> List ( String, Encode.Value )
baseLogFields request =
    [ ( "log_date", Encode.string (LocalDate.format request.logDate) )
    , ( "item", ItemRef.encoder request.item )
    , ( "quantity", Nutrition.quantityEncoder request.quantity )
    , ( "notes", Json.maybe Encode.string request.notes )
    ]


mealSlotField : Maybe String -> List ( String, Encode.Value )
mealSlotField maybeSlot =
    case maybeSlot of
        Just slot ->
            [ ( "meal_slot", Encode.string slot ) ]

        Nothing ->
            []


deviceTimezoneField : Maybe String -> List ( String, Encode.Value )
deviceTimezoneField maybeTimezone =
    case maybeTimezone of
        Just tz ->
            [ ( "device_timezone", Encode.string tz ) ]

        Nothing ->
            []


latestSlotResponseDecoder : Decode.Decoder LatestSlotResponse
latestSlotResponseDecoder =
    Decode.map3 LatestSlotResponse
        (Decode.field "source_date" dateFieldDecoder)
        (Decode.field "meal_slot" Decode.string)
        (Decode.field "items" (Decode.list FoodLog.decoder))


batchLogResponseDecoder : Decode.Decoder BatchLogResponse
batchLogResponseDecoder =
    Decode.map BatchLogResponse
        (Decode.field "items" (Decode.list FoodLog.decoder))


dateFieldDecoder : Decode.Decoder LocalDate
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
