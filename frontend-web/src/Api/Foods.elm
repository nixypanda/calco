module Api.Foods exposing
    ( NutrientEntry
    , ProductDetail
    , ProductName
    , SearchRequest
    , SearchResponse
    , SearchResult
    , ServingEntry
    , UnitItem
    , UnitListResponse
    , getFoodDetail
    , getProductName
    , listUnits
    , productDetailDecoder
    , searchFoods
    , searchPath
    , searchResponseDecoder
    , unitListResponseDecoder
    )

import Api.Client as Client
import Json.Decode as Decode exposing (Decoder)
import Url.Builder as Builder


type alias ProductName =
    { id : String
    , name : String
    }


type alias ProductDetail =
    { id : String
    , source : String
    , sourceId : Maybe String
    , visibility : String
    , barcode : Maybe String
    , name : String
    , brand : Maybe String
    , categories : List String
    , defaultQuantity : Maybe String
    , defaultUnit : Maybe String
    , servingSizeG : Maybe String
    , nutrients : List NutrientEntry
    , servings : List ServingEntry
    , allowedUnits : List UnitItem
    }


type alias NutrientEntry =
    { code : String
    , amountPer100g : String
    , unit : String
    , source : Maybe String
    , confidence : Maybe String
    }


type alias ServingEntry =
    { label : String
    , quantity : String
    , unit : String
    , grams : String
    }


type alias UnitItem =
    { code : String
    , name : String
    , kind : String
    }


type alias UnitListResponse =
    { items : List UnitItem
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


getFoodDetail : String -> (Result Client.ApiError ProductDetail -> msg) -> Cmd msg
getFoodDetail id toMsg =
    Client.get
        (Builder.absolute [ "api", "foods", id ] [])
        productDetailDecoder
        toMsg


listUnits : (Result Client.ApiError UnitListResponse -> msg) -> Cmd msg
listUnits toMsg =
    Client.get
        (Builder.absolute [ "api", "units" ] [])
        unitListResponseDecoder
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


productDetailDecoder : Decoder ProductDetail
productDetailDecoder =
    Decode.map8 ProductDetail
        (Decode.field "id" Decode.string)
        (Decode.field "source" Decode.string)
        (Decode.field "source_id" (Decode.nullable Decode.string))
        (Decode.field "visibility" Decode.string)
        (Decode.field "barcode" (Decode.nullable Decode.string))
        (Decode.field "name" Decode.string)
        (Decode.field "brand" (Decode.nullable Decode.string))
        (Decode.field "categories" (Decode.list Decode.string))
        |> andMap (Decode.field "default_quantity" (Decode.nullable Decode.string))
        |> andMap (Decode.field "default_unit" (Decode.nullable Decode.string))
        |> andMap (Decode.field "serving_size_g" (Decode.nullable Decode.string))
        |> andMap (Decode.field "nutrients" (Decode.list nutrientEntryDecoder))
        |> andMap (Decode.field "servings" (Decode.list servingEntryDecoder))
        |> andMap (Decode.field "allowed_units" (Decode.list unitItemDecoder))


nutrientEntryDecoder : Decoder NutrientEntry
nutrientEntryDecoder =
    Decode.map5 NutrientEntry
        (Decode.field "code" Decode.string)
        (Decode.field "amount_per_100g" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "source" (Decode.nullable Decode.string))
        (Decode.field "confidence" (Decode.nullable Decode.string))


servingEntryDecoder : Decoder ServingEntry
servingEntryDecoder =
    Decode.map4 ServingEntry
        (Decode.field "label" Decode.string)
        (Decode.field "quantity" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "grams" Decode.string)


unitListResponseDecoder : Decoder UnitListResponse
unitListResponseDecoder =
    Decode.map UnitListResponse
        (Decode.field "items" (Decode.list unitItemDecoder))


unitItemDecoder : Decoder UnitItem
unitItemDecoder =
    Decode.map3 UnitItem
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "kind" Decode.string)


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
