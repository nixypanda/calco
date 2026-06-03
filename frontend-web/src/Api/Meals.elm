module Api.Meals exposing (MealName, getMealName)

import Api.Client as Client
import Json.Decode as Decode exposing (Decoder)
import Url.Builder as Builder


type alias MealName =
    { id : String
    , name : String
    }


getMealName : String -> (Result Client.ApiError MealName -> msg) -> Cmd msg
getMealName id toMsg =
    Client.get
        (Builder.absolute [ "api", "meals", id ] [])
        decoder
        toMsg


decoder : Decoder MealName
decoder =
    Decode.map2 MealName
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
