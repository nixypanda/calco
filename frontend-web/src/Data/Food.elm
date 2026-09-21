module Data.Food exposing
    ( NutrientEntry
    , ProductDetail
    , ProductNutritionSummary
    , SearchResult
    , ServingEntry
    , UnitItem
    )

import Data.Nutrition exposing (NutritionSummary)


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
    , nutritionSummary : ProductNutritionSummary
    , nutrients : List NutrientEntry
    , servings : List ServingEntry
    , allowedUnits : List UnitItem
    }


type alias ProductNutritionSummary =
    { per100g : NutritionSummary }


type alias NutrientEntry =
    { code : String
    , amountPer100g : String
    , unit : String
    , source : Maybe String
    , confidence : Maybe String
    }


type alias ServingEntry =
    { unit : String, gramsPerUnit : String }


type alias UnitItem =
    { code : String, name : String, kind : String }


type alias SearchResult =
    { id : String
    , source : String
    , sourceId : Maybe String
    , barcode : Maybe String
    , name : String
    , brand : Maybe String
    , categories : List String
    , nutritionSummary : ProductNutritionSummary
    }
