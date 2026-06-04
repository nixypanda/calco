module Api.Logs exposing
    ( CreateLogRequest
    , UpdateLogRequest
    , createLog
    , createLogRequestEncoder
    , deleteLog
    , getLog
    , getSummary
    , listLogs
    , updateLog
    , updateLogRequestEncoder
    )

import Api.Client as Client
import Data.FoodLog as FoodLog exposing (FoodLog, SummaryResponse)
import Data.ItemRef exposing (ItemRef)
import Data.Quantity exposing (Quantity)
import Json.Encode as Encode
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Json as Json
import Url.Builder as Builder


type alias CreateLogRequest =
    { loggedAt : String
    , mealSlot : Maybe String
    , item : ItemRef
    , quantity : Quantity
    , notes : Maybe String
    }


type alias UpdateLogRequest =
    { mealSlot : Maybe String
    , quantity : Quantity
    , notes : Maybe String
    }


createLog : CreateLogRequest -> (Result Client.ApiError FoodLog -> msg) -> Cmd msg
createLog request toMsg =
    Client.post
        (Builder.absolute [ "api", "logs" ] [])
        (createLogRequestEncoder request)
        FoodLog.decoder
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


listLogs : LocalDate -> (Result Client.ApiError (List FoodLog) -> msg) -> Cmd msg
listLogs date toMsg =
    Client.get
        (Builder.absolute
            [ "api", "logs" ]
            [ Builder.string "from" (LocalDate.format date)
            , Builder.string "to" (LocalDate.format date)
            ]
        )
        FoodLog.listDecoder
        toMsg


getSummary : LocalDate -> (Result Client.ApiError SummaryResponse -> msg) -> Cmd msg
getSummary date toMsg =
    Client.get
        (Builder.absolute
            [ "api", "summary" ]
            [ Builder.string "from" (LocalDate.format date)
            , Builder.string "to" (LocalDate.format date)
            , Builder.string "codes" "ENERGY_KCAL,PROTEIN_G,CARBS_G,FAT_G"
            ]
        )
        FoodLog.summaryDecoder
        toMsg


createLogRequestEncoder : CreateLogRequest -> Encode.Value
createLogRequestEncoder request =
    Encode.object
        (baseLogFields request ++ mealSlotField request.mealSlot)


updateLogRequestEncoder : UpdateLogRequest -> Encode.Value
updateLogRequestEncoder request =
    Encode.object
        [ ( "quantity", quantityEncoder request.quantity )
        , ( "meal_slot", Json.maybe Encode.string request.mealSlot )
        , ( "notes", Json.maybe Encode.string request.notes )
        ]


baseLogFields : CreateLogRequest -> List ( String, Encode.Value )
baseLogFields request =
    [ ( "logged_at", Encode.string request.loggedAt )
    , ( "item", itemRefEncoder request.item )
    , ( "quantity", quantityEncoder request.quantity )
    , ( "notes", Json.maybe Encode.string request.notes )
    ]


mealSlotField : Maybe String -> List ( String, Encode.Value )
mealSlotField maybeSlot =
    case maybeSlot of
        Just slot ->
            [ ( "meal_slot", Encode.string slot ) ]

        Nothing ->
            []


itemRefEncoder : ItemRef -> Encode.Value
itemRefEncoder item =
    Encode.object
        [ ( "type", Encode.string item.itemType )
        , ( "id", Encode.string item.id )
        ]


quantityEncoder : Quantity -> Encode.Value
quantityEncoder quantity =
    Encode.object
        [ ( "amount", Encode.string quantity.amount )
        , ( "unit", Encode.string quantity.unit )
        ]
