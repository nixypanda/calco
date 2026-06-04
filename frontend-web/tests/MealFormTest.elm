module MealFormTest exposing (tests)

import Api.Foods exposing (SearchResult)
import Api.Meals exposing (Meal)
import Data.Nutrition exposing (NutrientAmount)
import Expect
import Page.Meal.Form as MealForm
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Form"
        [ test "new meal form starts with one empty component" <|
            \_ ->
                MealForm.initCreate
                    |> Tuple.first
                    |> .components
                    |> List.map (\row -> ( row.quantity, row.unit, row.productId ))
                    |> Expect.equal [ ( "100", "g", "" ) ]
        , test "name is required" <|
            \_ ->
                MealForm.toMealRequest (Tuple.first MealForm.initCreate)
                    |> Expect.equal (Err MealForm.MealNameRequired)
        , test "at least one selected product is required" <|
            \_ ->
                let
                    base : MealForm.Model
                    base =
                        Tuple.first MealForm.initCreate
                in
                MealForm.toMealRequest { base | name = "Lunch" }
                    |> Expect.equal (Err MealForm.ComponentRequired)
        , test "selected components default quantity to 100 g" <|
            \_ ->
                let
                    row : MealForm.ComponentRow
                    row =
                        MealForm.emptyComponentRow 1
                in
                MealForm.selectedComponents
                    [ { row | productId = "food-1", quantity = "", unit = "" } ]
                    |> Expect.equal
                        [ { item = { itemType = "product", id = "food-1" }
                          , quantity = { amount = "100", unit = "g" }
                          }
                        ]
        , test "total quantity is included only when present" <|
            \_ ->
                let
                    base : MealForm.Model
                    base =
                        Tuple.first MealForm.initCreate

                    row : MealForm.ComponentRow
                    row =
                        MealForm.emptyComponentRow 1
                in
                MealForm.toMealRequest
                    { base
                        | name = "Lunch"
                        , totalQuantity = "250"
                        , totalUnit = "g"
                        , components = [ { row | productId = "food-1" } ]
                    }
                    |> Result.map .totalQuantity
                    |> Expect.equal (Ok (Just { amount = "250", unit = "g" }))
        , test "stale row search result is ignored" <|
            \_ ->
                let
                    base : MealForm.Model
                    base =
                        Tuple.first MealForm.initCreate

                    row : MealForm.ComponentRow
                    row =
                        MealForm.emptyComponentRow 1

                    model : MealForm.Model
                    model =
                        { base | components = [ { row | searchToken = 2 } ] }
                in
                MealForm.update
                    (MealForm.ComponentSearchCompleted 1 1 (Ok { items = [ result ] }))
                    model
                    |> first
                    |> .components
                    |> List.head
                    |> Maybe.map .searchResults
                    |> Expect.equal (Just [])
        , test "matching row search result stores results" <|
            \_ ->
                let
                    base : MealForm.Model
                    base =
                        Tuple.first MealForm.initCreate

                    row : MealForm.ComponentRow
                    row =
                        MealForm.emptyComponentRow 1

                    model : MealForm.Model
                    model =
                        { base | components = [ { row | searchToken = 2 } ] }
                in
                MealForm.update
                    (MealForm.ComponentSearchCompleted 1 2 (Ok { items = [ result ] }))
                    model
                    |> first
                    |> .components
                    |> List.head
                    |> Maybe.map .searchResults
                    |> Expect.equal (Just [ result ])
        , test "component search tab completion expands include category operator" <|
            \_ ->
                MealForm.update
                    (MealForm.CompleteFirstComponentSuggestion 1)
                    (modelWithRow
                        { emptyRow | searchQuery = "c" }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "category:")
        , test "component search tab completion preserves the token gap" <|
            \_ ->
                MealForm.update
                    (MealForm.CompleteFirstComponentSuggestion 1)
                    (modelWithRow
                        { emptyRow | searchQuery = "apple c" }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "apple category:")
        , test "component category search requests suggestions and product search" <|
            \_ ->
                MealForm.update
                    (MealForm.ComponentSearchChanged 1 "category:foo")
                    (Tuple.first MealForm.initCreate)
                    |> third
                    |> Expect.equal
                        (MealForm.RequestProductAndCats
                            { rowId = 1
                            , searchToken = 1
                            , searchRequest = { query = "category:foo" }
                            , categoryToken = 2
                            , categoryRequest = { query = "foo", limit = 8 }
                            }
                        )
        , test "component category suggestions are stored" <|
            \_ ->
                MealForm.update
                    (MealForm.ComponentCategoriesCompleted 1
                        2
                        (Ok
                            { items =
                                [ { value = "food and beverages", count = 4 } ]
                            }
                        )
                    )
                    (modelWithRow
                        { emptyRow | categoryToken = 2 }
                    )
                    |> first
                    |> .components
                    |> List.head
                    |> Maybe.map .categorySuggestions
                    |> Expect.equal
                        (Just [ { value = "food and beverages", count = 4 } ])
        , test "component category value completion quotes spaces" <|
            \_ ->
                MealForm.update
                    (MealForm.CompleteFirstComponentSuggestion 1)
                    (modelWithRow
                        { emptyRow
                            | searchQuery = "category:foo"
                            , categorySuggestions =
                                [ { value = "food and beverages", count = 4 } ]
                        }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "category:\"food and beverages\"")
        , test "edit meal maps components into rows" <|
            \_ ->
                MealForm.update
                    (MealForm.MealLoaded (Ok meal))
                    (Tuple.first (MealForm.initEdit "meal-1"))
                    |> first
                    |> .components
                    |> List.map (\row -> ( row.productId, row.quantity, row.unit ))
                    |> Expect.equal [ ( "food-1", "2", "serving" ) ]
        , test "edit meal stores nutrient preview" <|
            \_ ->
                MealForm.update
                    (MealForm.NutrientPreviewLoaded (Ok nutrientPreview))
                    (Tuple.first (MealForm.initEdit "meal-1"))
                    |> first
                    |> .nutrients
                    |> Expect.equal (Just [ nutrient ])
        ]


result : SearchResult
result =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Rice"
    , brand = Nothing
    , categories = []
    , servingSizeG = Nothing
    , energyKcalPer100g = Nothing
    , energyKcalPerServing = Nothing
    }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


nutrientPreview :
    { mealId : String
    , nutrients : List NutrientAmount
    , quantity : { amount : String, unit : String }
    }
nutrientPreview =
    { mealId = "meal-1"
    , quantity = { amount = "100", unit = "g" }
    , nutrients = [ nutrient ]
    }


emptyRow : MealForm.ComponentRow
emptyRow =
    MealForm.emptyComponentRow 1


modelWithRow : MealForm.ComponentRow -> MealForm.Model
modelWithRow row =
    let
        base : MealForm.Model
        base =
            Tuple.first MealForm.initCreate
    in
    { base | components = [ row ] }


firstRowQuery : MealForm.Model -> Maybe String
firstRowQuery model =
    model.components
        |> List.head
        |> Maybe.map .searchQuery


meal : Meal
meal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { id = "component-1"
          , item = { itemType = "product", id = "food-1" }
          , quantity = { amount = "2", unit = "serving" }
          }
        ]
    , createdAt = "now"
    , updatedAt = "now"
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
