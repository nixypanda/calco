module Api.NutritionDetails exposing (get)

import Api.Client as Client
import Data.NutritionDetails exposing (NutritionDetails, decoder)
import Lib.Date as LocalDate exposing (LocalDate)
import Url.Builder as Builder


get : LocalDate -> (Result Client.ApiError NutritionDetails -> msg) -> Cmd msg
get date toMsg =
    Client.get
        (Builder.absolute [ "api", "nutrition", "details" ]
            [ Builder.string "date" (LocalDate.format date) ]
        )
        decoder
        toMsg
