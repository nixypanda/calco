module Api.Meals exposing
    ( CreateMealComponentRequest
    , CreateMealRequest
    , Meal
    , MealComponent
    , MealListResponse
    , MealName
    , MealNutrientsQuery
    , MealNutritionResponse
    , createMeal
    , deleteMeal
    , getMeal
    , getMealName
    , getMealNutrients
    , listMeals
    , updateMeal
    )

import Api.Client as Client
import Data.ItemRef as ItemRef exposing (ItemRef)
import Data.Nutrition as Nutrition exposing (NutrientAmount, NutritionSummary)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Lib.Json as Json
import Url.Builder as Builder


type alias MealName =
    { id : String
    , name : String
    }


type alias Meal =
    { id : String
    , name : String
    , notes : Maybe String
    , totalQuantity : Maybe Nutrition.Quantity
    , nutritionSummary : Maybe NutritionSummary
    , components : List MealComponent
    , createdAt : String
    , updatedAt : String
    }


type alias MealComponent =
    { id : String
    , item : ItemRef
    , quantity : Nutrition.Quantity
    , nutritionSummary : Maybe NutritionSummary
    }


type alias MealListResponse =
    { items : List Meal
    }


type alias CreateMealRequest =
    { name : String
    , notes : Maybe String
    , totalQuantity : Maybe Nutrition.Quantity
    , components : List CreateMealComponentRequest
    }


type alias CreateMealComponentRequest =
    { item : ItemRef
    , quantity : Nutrition.Quantity
    }


type alias MealNutritionResponse =
    { mealId : String
    , quantity : Nutrition.Quantity
    , nutritionSummary : NutritionSummary
    , nutrients : List NutrientAmount
    }


getMealName : String -> (Result Client.ApiError MealName -> msg) -> Cmd msg
getMealName id toMsg =
    Client.get
        (Builder.absolute [ "api", "meals", id ] [])
        decoder
        toMsg


listMeals : (Result Client.ApiError MealListResponse -> msg) -> Cmd msg
listMeals toMsg =
    Client.get
        (Builder.absolute [ "api", "meals" ] [])
        mealListDecoder
        toMsg


getMeal : String -> (Result Client.ApiError Meal -> msg) -> Cmd msg
getMeal id toMsg =
    Client.get
        (Builder.absolute [ "api", "meals", id ] [])
        mealDecoder
        toMsg


createMeal : CreateMealRequest -> (Result Client.ApiError Meal -> msg) -> Cmd msg
createMeal request toMsg =
    Client.post
        (Builder.absolute [ "api", "meals" ] [])
        (createMealRequestEncoder request)
        mealDecoder
        toMsg


updateMeal : String -> CreateMealRequest -> (Result Client.ApiError Meal -> msg) -> Cmd msg
updateMeal id request toMsg =
    Client.put
        (Builder.absolute [ "api", "meals", id ] [])
        (createMealRequestEncoder request)
        mealDecoder
        toMsg


deleteMeal : String -> (Result Client.ApiError () -> msg) -> Cmd msg
deleteMeal id toMsg =
    Client.delete
        (Builder.absolute [ "api", "meals", id ] [])
        toMsg


type alias MealNutrientsQuery =
    { mealId : String
    , amount : String
    , unit : String
    }


getMealNutrients :
    MealNutrientsQuery
    -> (Result Client.ApiError MealNutritionResponse -> msg)
    -> Cmd msg
getMealNutrients query toMsg =
    Client.get
        (Builder.absolute
            [ "api", "meals", query.mealId, "nutrients" ]
            [ Builder.string "amount" query.amount
            , Builder.string "unit" query.unit
            ]
        )
        mealNutritionDecoder
        toMsg


createMealRequestEncoder : CreateMealRequest -> Encode.Value
createMealRequestEncoder request =
    Encode.object
        [ ( "name", Encode.string request.name )
        , ( "notes", Json.maybe Encode.string request.notes )
        , ( "total_quantity", Json.maybe Nutrition.quantityEncoder request.totalQuantity )
        , ( "components", Encode.list componentRequestEncoder request.components )
        ]


componentRequestEncoder : CreateMealComponentRequest -> Encode.Value
componentRequestEncoder component =
    Encode.object
        [ ( "item", ItemRef.encoder component.item )
        , ( "quantity", Nutrition.quantityEncoder component.quantity )
        ]


decoder : Decoder MealName
decoder =
    Decode.map2 MealName
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)


mealListDecoder : Decoder MealListResponse
mealListDecoder =
    Decode.map MealListResponse
        (Decode.field "items" (Decode.list mealDecoder))


mealDecoder : Decoder Meal
mealDecoder =
    Decode.map8 Meal
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "notes" (Decode.nullable Decode.string))
        (Decode.field "total_quantity" (Decode.nullable Nutrition.quantityDecoder))
        (Decode.field "nutrition_summary" (Decode.nullable Nutrition.summaryDecoder))
        (Decode.field "components" (Decode.list mealComponentDecoder))
        (Decode.field "created_at" Decode.string)
        (Decode.field "updated_at" Decode.string)


mealComponentDecoder : Decoder MealComponent
mealComponentDecoder =
    Decode.map4 MealComponent
        (Decode.field "id" Decode.string)
        (Decode.field "item" ItemRef.decoder)
        (Decode.field "quantity" Nutrition.quantityDecoder)
        (Decode.field "nutrition_summary" (Decode.nullable Nutrition.summaryDecoder))


mealNutritionDecoder : Decoder MealNutritionResponse
mealNutritionDecoder =
    Decode.map4 MealNutritionResponse
        (Decode.field "meal_id" Decode.string)
        (Decode.field "quantity" Nutrition.quantityDecoder)
        (Decode.field "nutrition_summary" Nutrition.summaryDecoder)
        (Decode.field "nutrients" (Decode.list Nutrition.decoder))
