module Api.Foods exposing
    ( CategorySuggestion
    , CategorySuggestionRequest
    , CategorySuggestionResponse
    , CreateFoodNutrientRequest
    , CreateFoodRequest
    , CreateFoodResponse
    , CreateFoodServingRequest
    , CustomFoodListResponse
    , NutrientEntry
    , NutrientItem
    , NutrientListResponse
    , ProductDetail
    , ProductNutritionSummary
    , SearchRequest
    , SearchResponse
    , SearchResult
    , SearchScope(..)
    , ServingEntry
    , UnitItem
    , UnitListResponse
    , barcodePath
    , categorySuggestionPath
    , categorySuggestionResponseDecoder
    , createCustomFood
    , deleteCustomFood
    , getFoodDetail
    , listCategorySuggestions
    , listCustomFoods
    , listNutrients
    , listUnits
    , lookupBarcode
    , productDetailDecoder
    , searchFoods
    , searchPath
    , searchResponseDecoder
    , unitListResponseDecoder
    , updateCustomFood
    )

import Api.Client as Client
import Data.Nutrition as Nutrition exposing (NutritionSummary)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Lib.Json as Json
import Url
import Url.Builder as Builder


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
    , nutritionSummary : ProductNutritionSummary
    , nutrients : List NutrientEntry
    , servings : List ServingEntry
    , allowedUnits : List UnitItem
    }


type alias ProductNutritionSummary =
    { per100g : NutritionSummary
    , perServing : Maybe NutritionSummary
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


type alias NutrientItem =
    { code : String
    , name : String
    , unit : String
    , category : String
    }


type alias NutrientListResponse =
    { items : List NutrientItem
    }


type alias CreateFoodRequest =
    { name : String
    , brand : Maybe String
    , categories : List String
    , servingSizeG : Maybe String
    , defaultQuantity : Maybe String
    , defaultUnit : Maybe String
    , nutrients : List CreateFoodNutrientRequest
    , servings : List CreateFoodServingRequest
    }


type alias CreateFoodNutrientRequest =
    { code : String
    , amountPer100g : Float
    }


type alias CreateFoodServingRequest =
    { label : String
    , quantity : Float
    , unit : String
    , grams : Float
    }


type alias CreateFoodResponse =
    { id : String
    }


type alias CustomFoodListResponse =
    { items : List ProductDetail
    }


type alias SearchRequest =
    { query : String
    , scope : SearchScope
    }


type SearchScope
    = SearchAll
    | SearchHistory
    | SearchCustom


type alias SearchResponse =
    { items : List SearchResult
    }


type alias CategorySuggestionRequest =
    { query : String
    , limit : Int
    }


type alias CategorySuggestionResponse =
    { items : List CategorySuggestion
    }


type alias CategorySuggestion =
    { value : String
    , count : Int
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
    , nutritionSummary : ProductNutritionSummary
    , energyKcalPer100g : Maybe String
    , energyKcalPerServing : Maybe String
    }


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


listNutrients : (Result Client.ApiError NutrientListResponse -> msg) -> Cmd msg
listNutrients toMsg =
    Client.get
        (Builder.absolute [ "api", "nutrients" ] [])
        nutrientListResponseDecoder
        toMsg


searchFoods : SearchRequest -> (Result Client.ApiError SearchResponse -> msg) -> Cmd msg
searchFoods request toMsg =
    Client.get
        (searchPath request)
        searchResponseDecoder
        toMsg


lookupBarcode : String -> (Result Client.ApiError ProductDetail -> msg) -> Cmd msg
lookupBarcode barcode toMsg =
    Client.get
        (barcodePath barcode)
        productDetailDecoder
        toMsg


listCategorySuggestions :
    CategorySuggestionRequest
    -> (Result Client.ApiError CategorySuggestionResponse -> msg)
    -> Cmd msg
listCategorySuggestions request toMsg =
    Client.get
        (categorySuggestionPath request)
        categorySuggestionResponseDecoder
        toMsg


createCustomFood :
    CreateFoodRequest
    -> (Result Client.ApiError CreateFoodResponse -> msg)
    -> Cmd msg
createCustomFood request toMsg =
    Client.post
        (Builder.absolute [ "api", "foods", "custom" ] [])
        (createFoodRequestEncoder request)
        createFoodResponseDecoder
        toMsg


updateCustomFood :
    String
    -> CreateFoodRequest
    -> (Result Client.ApiError CreateFoodResponse -> msg)
    -> Cmd msg
updateCustomFood id request toMsg =
    Client.put
        (Builder.absolute [ "api", "foods", "custom", id ] [])
        (createFoodRequestEncoder request)
        createFoodResponseDecoder
        toMsg


listCustomFoods :
    (Result Client.ApiError CustomFoodListResponse -> msg)
    -> Cmd msg
listCustomFoods toMsg =
    Client.get
        (Builder.absolute [ "api", "foods", "custom" ] [])
        customFoodListDecoder
        toMsg


deleteCustomFood : String -> (Result Client.ApiError () -> msg) -> Cmd msg
deleteCustomFood id toMsg =
    Client.delete
        (Builder.absolute [ "api", "foods", "custom", id ] [])
        toMsg


searchPath : SearchRequest -> String
searchPath request =
    Builder.absolute [ "api", "foods", "search" ]
        [ Builder.string "q" request.query
        , Builder.string "scope" (searchScopeToString request.scope)
        ]


searchScopeToString : SearchScope -> String
searchScopeToString scope =
    case scope of
        SearchAll ->
            "all"

        SearchHistory ->
            "history"

        SearchCustom ->
            "custom"


barcodePath : String -> String
barcodePath barcode =
    Builder.absolute [ "api", "foods", "barcode", Url.percentEncode barcode ] []


categorySuggestionPath : CategorySuggestionRequest -> String
categorySuggestionPath request =
    Builder.absolute [ "api", "foods", "categories" ]
        [ Builder.string "q" request.query
        , Builder.int "limit" request.limit
        ]


createFoodRequestEncoder : CreateFoodRequest -> Encode.Value
createFoodRequestEncoder request =
    Encode.object
        [ ( "name", Encode.string request.name )
        , ( "brand", Json.maybe Encode.string request.brand )
        , ( "categories", Encode.list Encode.string request.categories )
        , ( "serving_size_g", Json.maybe Encode.string request.servingSizeG )
        , ( "default_quantity", Json.maybe Encode.string request.defaultQuantity )
        , ( "default_unit", Json.maybe Encode.string request.defaultUnit )
        , ( "nutrients", Encode.list nutrientRequestEncoder request.nutrients )
        , ( "servings", Encode.list servingRequestEncoder request.servings )
        ]


nutrientRequestEncoder : CreateFoodNutrientRequest -> Encode.Value
nutrientRequestEncoder nutrient =
    Encode.object
        [ ( "code", Encode.string nutrient.code )
        , ( "amount_per_100g", Encode.float nutrient.amountPer100g )
        ]


servingRequestEncoder : CreateFoodServingRequest -> Encode.Value
servingRequestEncoder serving =
    Encode.object
        [ ( "label", Encode.string serving.label )
        , ( "quantity", Encode.float serving.quantity )
        , ( "unit", Encode.string serving.unit )
        , ( "grams", Encode.float serving.grams )
        ]


searchResponseDecoder : Decoder SearchResponse
searchResponseDecoder =
    Decode.map SearchResponse
        (Decode.field "items" (Decode.list searchResultDecoder))


categorySuggestionResponseDecoder : Decoder CategorySuggestionResponse
categorySuggestionResponseDecoder =
    Decode.map CategorySuggestionResponse
        (Decode.field "items" (Decode.list categorySuggestionDecoder))


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
        |> Json.andMap (Decode.field "default_quantity" (Decode.nullable Decode.string))
        |> Json.andMap (Decode.field "default_unit" (Decode.nullable Decode.string))
        |> Json.andMap (Decode.field "serving_size_g" (Decode.nullable Decode.string))
        |> Json.andMap (Decode.field "nutrition_summary" productNutritionSummaryDecoder)
        |> Json.andMap (Decode.field "nutrients" (Decode.list nutrientEntryDecoder))
        |> Json.andMap (Decode.field "servings" (Decode.list servingEntryDecoder))
        |> Json.andMap (Decode.field "allowed_units" (Decode.list unitItemDecoder))


productNutritionSummaryDecoder : Decoder ProductNutritionSummary
productNutritionSummaryDecoder =
    Decode.map2 ProductNutritionSummary
        (Decode.field "per_100g" Nutrition.summaryDecoder)
        (Decode.field "per_serving" (Decode.nullable Nutrition.summaryDecoder))


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


nutrientListResponseDecoder : Decoder NutrientListResponse
nutrientListResponseDecoder =
    Decode.map NutrientListResponse
        (Decode.field "items" (Decode.list nutrientItemDecoder))


nutrientItemDecoder : Decoder NutrientItem
nutrientItemDecoder =
    Decode.map4 NutrientItem
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "category" Decode.string)


createFoodResponseDecoder : Decoder CreateFoodResponse
createFoodResponseDecoder =
    Decode.map CreateFoodResponse
        (Decode.field "id" Decode.string)


customFoodListDecoder : Decoder CustomFoodListResponse
customFoodListDecoder =
    Decode.map CustomFoodListResponse
        (Decode.field "items" (Decode.list productDetailDecoder))


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
        |> Json.andMap (Decode.field "nutrition_summary" productNutritionSummaryDecoder)
        |> Json.andMap (Decode.field "energy_kcal_per_100g" (Decode.nullable Decode.string))
        |> Json.andMap (Decode.field "energy_kcal_per_serving" (Decode.nullable Decode.string))


categorySuggestionDecoder : Decoder CategorySuggestion
categorySuggestionDecoder =
    Decode.map2 CategorySuggestion
        (Decode.field "value" Decode.string)
        (Decode.field "count" Decode.int)
