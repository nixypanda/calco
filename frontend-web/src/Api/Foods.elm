module Api.Foods exposing
    ( BarcodeLookupMetadata
    , BarcodeLookupOrigin(..)
    , BarcodeLookupResponse
    , CategorySuggestion
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
    , barcodeLookupResponseDecoder
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
import Data.Food as Food
import Data.Nutrition as Nutrition
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Lib.Json as Json
import Url
import Url.Builder as Builder


type alias ProductDetail =
    Food.ProductDetail


type alias BarcodeLookupResponse =
    { product : ProductDetail, lookup : BarcodeLookupMetadata }


type alias BarcodeLookupMetadata =
    { origin : BarcodeLookupOrigin, note : Maybe String }


type BarcodeLookupOrigin
    = Local
    | OpenFoodFacts


type alias ProductNutritionSummary =
    Food.ProductNutritionSummary


type alias NutrientEntry =
    Food.NutrientEntry


type alias ServingEntry =
    Food.ServingEntry


type alias UnitItem =
    Food.UnitItem


type alias UnitListResponse =
    { items : List UnitItem }


type alias NutrientItem =
    { code : String, name : String, unit : String, category : String }


type alias NutrientListResponse =
    { items : List NutrientItem }


type alias CreateFoodRequest =
    { name : String
    , brand : Maybe String
    , categories : List String
    , defaultQuantity : Maybe String
    , defaultUnit : Maybe String
    , nutrients : List CreateFoodNutrientRequest
    , servings : List CreateFoodServingRequest
    }


type alias CreateFoodNutrientRequest =
    { code : String, amountPer100g : Float }


type alias CreateFoodServingRequest =
    { unit : String, gramsPerUnit : Float }


type alias CreateFoodResponse =
    { id : String }


type alias CustomFoodListResponse =
    { items : List ProductDetail }


type alias SearchRequest =
    { query : String, scope : SearchScope }


type SearchScope
    = SearchAll
    | SearchHistory
    | SearchCustom


type alias SearchResponse =
    { items : List SearchResult }


type alias CategorySuggestionRequest =
    { query : String, limit : Int }


type alias CategorySuggestionResponse =
    { items : List CategorySuggestion }


type alias CategorySuggestion =
    { value : String, count : Int }


type alias SearchResult =
    Food.SearchResult


getFoodDetail : String -> (Result Client.ApiError ProductDetail -> msg) -> Cmd msg
getFoodDetail id toMsg =
    Client.get (Builder.absolute [ "api", "foods", id ] []) productDetailDecoder toMsg


listUnits : (Result Client.ApiError UnitListResponse -> msg) -> Cmd msg
listUnits toMsg =
    Client.get (Builder.absolute [ "api", "units" ] []) unitListResponseDecoder toMsg


listNutrients : (Result Client.ApiError NutrientListResponse -> msg) -> Cmd msg
listNutrients toMsg =
    Client.get (Builder.absolute [ "api", "nutrients" ] []) nutrientListResponseDecoder toMsg


searchFoods : SearchRequest -> (Result Client.ApiError SearchResponse -> msg) -> Cmd msg
searchFoods request toMsg =
    Client.get (searchPath request) searchResponseDecoder toMsg


lookupBarcode : String -> (Result Client.ApiError BarcodeLookupResponse -> msg) -> Cmd msg
lookupBarcode barcode toMsg =
    Client.get (barcodePath barcode) barcodeLookupResponseDecoder toMsg


listCategorySuggestions :
    CategorySuggestionRequest
    -> (Result Client.ApiError CategorySuggestionResponse -> msg)
    -> Cmd msg
listCategorySuggestions request toMsg =
    Client.get (categorySuggestionPath request) categorySuggestionResponseDecoder toMsg


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


listCustomFoods : (Result Client.ApiError CustomFoodListResponse -> msg) -> Cmd msg
listCustomFoods toMsg =
    Client.get (Builder.absolute [ "api", "foods", "custom" ] []) customFoodListDecoder toMsg


deleteCustomFood : String -> (Result Client.ApiError () -> msg) -> Cmd msg
deleteCustomFood id toMsg =
    Client.delete (Builder.absolute [ "api", "foods", "custom", id ] []) toMsg


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
        [ Builder.string "q" request.query, Builder.int "limit" request.limit ]


createFoodRequestEncoder : CreateFoodRequest -> Encode.Value
createFoodRequestEncoder request =
    Encode.object
        [ ( "name", Encode.string request.name )
        , ( "brand", Json.maybe Encode.string request.brand )
        , ( "categories", Encode.list Encode.string request.categories )
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
        [ ( "unit", Encode.string serving.unit )
        , ( "grams_per_unit", Encode.float serving.gramsPerUnit )
        ]


searchResponseDecoder : Decoder SearchResponse
searchResponseDecoder =
    Decode.map SearchResponse (Decode.field "items" (Decode.list searchResultDecoder))


categorySuggestionResponseDecoder : Decoder CategorySuggestionResponse
categorySuggestionResponseDecoder =
    Decode.map CategorySuggestionResponse
        (Decode.field "items" (Decode.list categorySuggestionDecoder))


productDetailDecoder : Decoder ProductDetail
productDetailDecoder =
    Decode.map8 Food.ProductDetail
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
        |> Json.andMap (Decode.field "nutrition_summary" productNutritionSummaryDecoder)
        |> Json.andMap (Decode.field "nutrients" (Decode.list nutrientEntryDecoder))
        |> Json.andMap (Decode.field "servings" (Decode.list servingEntryDecoder))
        |> Json.andMap (Decode.field "allowed_units" (Decode.list unitItemDecoder))


barcodeLookupResponseDecoder : Decoder BarcodeLookupResponse
barcodeLookupResponseDecoder =
    Decode.map2 BarcodeLookupResponse
        productDetailDecoder
        (Decode.field "lookup" barcodeLookupMetadataDecoder)


barcodeLookupMetadataDecoder : Decoder BarcodeLookupMetadata
barcodeLookupMetadataDecoder =
    Decode.map2 BarcodeLookupMetadata
        (Decode.field "origin" barcodeLookupOriginDecoder)
        (Decode.field "note" (Decode.nullable Decode.string))


barcodeLookupOriginDecoder : Decoder BarcodeLookupOrigin
barcodeLookupOriginDecoder =
    Decode.string
        |> Decode.andThen
            (\value ->
                case value of
                    "local" ->
                        Decode.succeed Local

                    "open_food_facts" ->
                        Decode.succeed OpenFoodFacts

                    _ ->
                        Decode.fail ("unknown barcode lookup origin: " ++ value)
            )


productNutritionSummaryDecoder : Decoder ProductNutritionSummary
productNutritionSummaryDecoder =
    Decode.map Food.ProductNutritionSummary (Decode.field "per_100g" Nutrition.summaryDecoder)


nutrientEntryDecoder : Decoder NutrientEntry
nutrientEntryDecoder =
    Decode.map5 Food.NutrientEntry
        (Decode.field "code" Decode.string)
        (Decode.field "amount_per_100g" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "source" (Decode.nullable Decode.string))
        (Decode.field "confidence" (Decode.nullable Decode.string))


servingEntryDecoder : Decoder ServingEntry
servingEntryDecoder =
    Decode.map2 Food.ServingEntry
        (Decode.field "unit" Decode.string)
        (Decode.field "grams_per_unit" Decode.string)


unitListResponseDecoder : Decoder UnitListResponse
unitListResponseDecoder =
    Decode.map UnitListResponse (Decode.field "items" (Decode.list unitItemDecoder))


nutrientListResponseDecoder : Decoder NutrientListResponse
nutrientListResponseDecoder =
    Decode.map NutrientListResponse (Decode.field "items" (Decode.list nutrientItemDecoder))


nutrientItemDecoder : Decoder NutrientItem
nutrientItemDecoder =
    Decode.map4 NutrientItem
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "unit" Decode.string)
        (Decode.field "category" Decode.string)


createFoodResponseDecoder : Decoder CreateFoodResponse
createFoodResponseDecoder =
    Decode.map CreateFoodResponse (Decode.field "id" Decode.string)


customFoodListDecoder : Decoder CustomFoodListResponse
customFoodListDecoder =
    Decode.map CustomFoodListResponse (Decode.field "items" (Decode.list productDetailDecoder))


unitItemDecoder : Decoder UnitItem
unitItemDecoder =
    Decode.map3 Food.UnitItem
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "kind" Decode.string)


searchResultDecoder : Decoder SearchResult
searchResultDecoder =
    Decode.map7 Food.SearchResult
        (Decode.field "id" Decode.string)
        (Decode.field "source" Decode.string)
        (Decode.field "source_id" (Decode.nullable Decode.string))
        (Decode.field "barcode" (Decode.nullable Decode.string))
        (Decode.field "name" Decode.string)
        (Decode.field "brand" (Decode.nullable Decode.string))
        (Decode.field "categories" (Decode.list Decode.string))
        |> Json.andMap (Decode.field "nutrition_summary" productNutritionSummaryDecoder)


categorySuggestionDecoder : Decoder CategorySuggestion
categorySuggestionDecoder =
    Decode.map2 CategorySuggestion
        (Decode.field "value" Decode.string)
        (Decode.field "count" Decode.int)
