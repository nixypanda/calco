module Page.Meal.CreateTest exposing (tests)

import Api.Foods exposing (SearchResult, SearchScope(..))
import Api.Meals exposing (Meal)
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Expect
import Lib.Loadable exposing (Loadable(..))
import Page.Meal.Create as MealCreate
import Page.Meal.Form as Common
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Form.Create"
        [ test "new meal form starts with one empty component" <|
            \_ ->
                MealCreate.init
                    |> Tuple.first
                    |> componentsOf
                    |> List.map (\row -> ( row.quantity, row.unit, row.productId ))
                    |> Expect.equal [ ( "100", "g", "" ) ]
        , test "name is required" <|
            \_ ->
                MealCreate.init
                    |> Tuple.first
                    |> Common.toMealRequest
                    |> Expect.equal (Err Common.MealNameRequired)
        , test "at least one selected product is required" <|
            \_ ->
                Common.toMealRequest
                    { emptyFormFields
                        | name = "Lunch"
                    }
                    |> Expect.equal (Err Common.ComponentRequired)
        , test "selected components default quantity to 100 g" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                Common.toMealRequest
                    { emptyFormFields
                        | name = "Lunch"
                        , components = [ { row | productId = "food-1", quantity = "", unit = "" } ]
                    }
                    |> Result.map .components
                    |> Expect.equal
                        (Ok
                            [ { item = { itemType = ItemRef.Product, id = "food-1" }
                              , quantity = { amount = "100", unit = "g" }
                              }
                            ]
                        )
        , test "total quantity is included only when present" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                Common.toMealRequest
                    { emptyFormFields
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
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                MealCreate.update
                    (MealCreate.FormMsg
                        (Common.ComponentSearchCompleted 1 1 (Ok { items = [ result ] }))
                    )
                    { emptyFormFields
                        | components =
                            [ { row
                                | search =
                                    Search.withSearchToken 2 row.search
                              }
                            ]
                    }
                    |> first
                    |> componentsOf
                    |> List.head
                    |> Maybe.map .searchResults
                    |> Expect.equal (Just NotAsked)
        , test "matching row search result stores results" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                MealCreate.update
                    (MealCreate.FormMsg
                        (Common.ComponentSearchCompleted 1 2 (Ok { items = [ result ] }))
                    )
                    { emptyFormFields
                        | components =
                            [ { row
                                | search =
                                    Search.withSearchToken 2 row.search
                              }
                            ]
                    }
                    |> first
                    |> componentsOf
                    |> List.head
                    |> Maybe.map .searchResults
                    |> Expect.equal (Just (Success [ result ]))
        , test "component search tab completion expands include category operator" <|
            \_ ->
                MealCreate.update
                    (MealCreate.FormMsg (Common.CompleteFirstComponentSuggestion 1))
                    (modelWithRow
                        { emptyRow | search = Search.withQuery "c" emptyRow.search }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "category:")
        , test "component search tab completion preserves the token gap" <|
            \_ ->
                MealCreate.update
                    (MealCreate.FormMsg (Common.CompleteFirstComponentSuggestion 1))
                    (modelWithRow
                        { emptyRow | search = Search.withQuery "apple c" emptyRow.search }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "apple category:")
        , test "component category search requests suggestions and product search" <|
            \_ ->
                MealCreate.update
                    (MealCreate.FormMsg (Common.ComponentSearchChanged 1 "category:foo"))
                    (Tuple.first MealCreate.init)
                    |> third
                    |> Expect.equal
                        (MealCreate.FormOutMsg
                            (Common.RequestProductAndCats
                                { rowId = 1
                                , searchToken = 1
                                , searchRequest =
                                    { query = "category:foo", scope = SearchAll }
                                , categoryToken = 2
                                , categoryRequest = { query = "foo", limit = 8 }
                                }
                            )
                        )
        , test "component category suggestions are stored" <|
            \_ ->
                MealCreate.update
                    (MealCreate.FormMsg
                        (Common.ComponentCategoriesCompleted 1
                            2
                            (Ok
                                { items =
                                    [ { value = "food and beverages", count = 4 } ]
                                }
                            )
                        )
                    )
                    (modelWithRow
                        { emptyRow
                            | search = Search.withCategoryToken 2 emptyRow.search
                        }
                    )
                    |> first
                    |> componentsOf
                    |> List.head
                    |> Maybe.map .search
                    |> Maybe.map .categorySuggestions
                    |> Expect.equal
                        (Just [ { value = "food and beverages", count = 4 } ])
        , test "component category value completion quotes spaces" <|
            \_ ->
                MealCreate.update
                    (MealCreate.FormMsg (Common.CompleteFirstComponentSuggestion 1))
                    (modelWithRow
                        { emptyRow
                            | search =
                                { query = "category:foo"
                                , searchToken = 0
                                , categoryToken = 0
                                , categorySuggestions =
                                    [ { value = "food and beverages", count = 4 } ]
                                }
                        }
                    )
                    |> first
                    |> firstRowQuery
                    |> Expect.equal (Just "category:\"food and beverages\"")
        , test "submit navigates to meal detail on save success" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                MealCreate.update
                    (MealCreate.SaveCompleted (Ok meal))
                    { emptyFormFields
                        | name = "Lunch"
                        , components = [ { row | productId = "food-1" } ]
                    }
                    |> third
                    |> Expect.equal (MealCreate.Navigate (MealShow "meal-1"))
        , test "submit with no name surfaces a name-required error" <|
            \_ ->
                MealCreate.update
                    MealCreate.SubmitClicked
                    emptyFormFields
                    |> first
                    |> .submit
                    |> Common.submitErrorMessage
                    |> Expect.equal (Just "Name is required")
        , test "submit with no selected product surfaces a component-required error" <|
            \_ ->
                MealCreate.update
                    MealCreate.SubmitClicked
                    { emptyFormFields | name = "Lunch" }
                    |> first
                    |> .submit
                    |> Common.submitErrorMessage
                    |> Expect.equal
                        (Just
                            "At least one component with a selected product is required"
                        )
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
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
    , energyKcalPer100g = Nothing
    , energyKcalPerServing = Nothing
    }


emptyRow : Common.ComponentRow
emptyRow =
    Common.emptyComponentRow 1


emptyFormFields : Common.FormFields
emptyFormFields =
    Common.emptyFormFields


modelWithRow : Common.ComponentRow -> Common.FormFields
modelWithRow row =
    { emptyFormFields | components = [ row ] }


firstRowQuery : Common.FormFields -> Maybe String
firstRowQuery model =
    componentsOf model
        |> List.head
        |> Maybe.map .search
        |> Maybe.map .query


componentsOf : Common.FormFields -> List Common.ComponentRow
componentsOf form =
    form.components


meal : Meal
meal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , nutritionSummary = Nothing
    , components =
        [ { id = "component-1"
          , item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "2", unit = "serving" }
          , nutritionSummary = Nothing
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
