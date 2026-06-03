module Api.Foods exposing (ProductName, getProductName)

import Api.Client as Client
import Json.Decode as Decode exposing (Decoder)
import Url.Builder as Builder


type alias ProductName =
    { id : String
    , name : String
    }


getProductName : String -> (Result Client.ApiError ProductName -> msg) -> Cmd msg
getProductName id toMsg =
    Client.get
        (Builder.absolute [ "api", "foods", id ] [])
        decoder
        toMsg


decoder : Decoder ProductName
decoder =
    Decode.map2 ProductName
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
