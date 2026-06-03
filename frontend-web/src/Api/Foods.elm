module Api.Foods exposing
    ( ProductName
    , SearchRequest
    , SearchResponse
    , SearchResult
    , getProductName
    , searchFoods
    , searchPath
    , searchResponseDecoder
    )

import Api.Client as Client
import Json.Decode as Decode exposing (Decoder)
import Url.Builder as Builder


type alias ProductName =
    { id : String
    , name : String
    }


type alias SearchRequest =
    { query : String
    }


type alias SearchResponse =
    { items : List SearchResult
    }


type alias SearchResult =
    { id : String
    , source : String
    , sourceId : Maybe String
    , barcode : Maybe String
    , name : String
    , brand : Maybe String
    , categories : List String
    , servingSizeG : Maybe String
    , energyKcalPer100g : Maybe String
    , energyKcalPerServing : Maybe String
    }


getProductName : String -> (Result Client.ApiError ProductName -> msg) -> Cmd msg
getProductName id toMsg =
    Client.get
        (Builder.absolute [ "api", "foods", id ] [])
        decoder
        toMsg


searchFoods : SearchRequest -> (Result Client.ApiError SearchResponse -> msg) -> Cmd msg
searchFoods request toMsg =
    Client.get
        (searchPath request)
        searchResponseDecoder
        toMsg


searchPath : SearchRequest -> String
searchPath request =
    Builder.absolute [ "api", "foods", "search" ]
        [ Builder.string "q" request.query ]


decoder : Decoder ProductName
decoder =
    Decode.map2 ProductName
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)


searchResponseDecoder : Decoder SearchResponse
searchResponseDecoder =
    Decode.map SearchResponse
        (Decode.field "items" (Decode.list searchResultDecoder))


searchResultDecoder : Decoder SearchResult
searchResultDecoder =
    Decode.map8 SearchResult
        (Decode.field "id" Decode.string)
        (Decode.field "source" Decode.string)
        (Decode.field "source_id" (Decode.nullable Decode.string))
        (Decode.field "barcode" (Decode.nullable Decode.string))
        (Decode.field "name" Decode.string)
        (Decode.field "brand" (Decode.nullable Decode.string))
        (Decode.field "categories" (Decode.list Decode.string))
        (Decode.field "serving_size_g" (Decode.nullable Decode.string))
        |> andMap (Decode.field "energy_kcal_per_100g" (Decode.nullable Decode.string))
        |> andMap (Decode.field "energy_kcal_per_serving" (Decode.nullable Decode.string))


andMap : Decoder value -> Decoder (value -> result) -> Decoder result
andMap valueDecoder functionDecoder =
    Decode.map2 (<|) functionDecoder valueDecoder
