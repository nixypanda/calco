module Api.Logs exposing (getSummary, listLogs)

import Api.Client as Client
import Data.FoodLog as FoodLog exposing (FoodLog, SummaryResponse)
import Data.LocalDate as LocalDate exposing (LocalDate)
import Url.Builder as Builder


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
