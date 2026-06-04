module MealFormTest exposing (tests)

import Api.Foods exposing (SearchResult)
import Api.Meals exposing (Meal)
import Expect
import Page.MealForm as MealForm
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.MealForm"
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
        , test "edit meal maps components into rows" <|
            \_ ->
                MealForm.update
                    (MealForm.MealLoaded (Ok meal))
                    (Tuple.first (MealForm.initEdit "meal-1"))
                    |> first
                    |> .components
                    |> List.map (\row -> ( row.productId, row.quantity, row.unit ))
                    |> Expect.equal [ ( "food-1", "2", "serving" ) ]
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
