module CustomFoodFormTest exposing (tests)

import Api.Foods exposing (ProductDetail, UnitItem)
import Expect
import Test exposing (Test, describe, test)
import View.CustomFoodForm as Form


tests : Test
tests =
    describe "View.CustomFoodForm"
        [ test "empty form has one nutrient row" <|
            \_ ->
                Form.emptyForm.nutrients
                    |> List.length
                    |> Expect.equal 1
        , test "name is required" <|
            \_ ->
                Form.toCreateFoodRequest Form.emptyForm
                    |> Expect.equal (Err Form.NameRequired)
        , test "categories are trimmed lowercased and deduplicated" <|
            \_ ->
                Form.parseCategoriesInput " Fruit, snack, fruit , SNACK "
                    |> Expect.equal [ "fruit", "snack" ]
        , test "payload filters incomplete rows and maps blanks to null" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "  Paneer  "
                        , brand = " "
                        , servingSizeG = ""
                        , defaultQuantity = ""
                        , nutrients =
                            [ { code = "PROTEIN_G", amountPer100g = "18" }
                            , { code = "", amountPer100g = "4" }
                            ]
                        , servings =
                            [ { label = "cube"
                              , quantity = "2"
                              , unit = "piece"
                              , grams = "50"
                              }
                            , { label = "bad", quantity = "", unit = "g", grams = "5" }
                            ]
                    }
                    |> Result.map
                        (\request ->
                            { name = request.name
                            , brand = request.brand
                            , servingSizeG = request.servingSizeG
                            , defaultQuantity = request.defaultQuantity
                            , nutrients = request.nutrients
                            , servings = request.servings
                            }
                        )
                    |> Expect.equal
                        (Ok
                            { name = "Paneer"
                            , brand = Nothing
                            , servingSizeG = Nothing
                            , defaultQuantity = Nothing
                            , nutrients = [ { code = "PROTEIN_G", amountPer100g = "18" } ]
                            , servings =
                                [ { label = "cube"
                                  , quantity = "2"
                                  , unit = "piece"
                                  , grams = "50"
                                  }
                                ]
                            }
                        )
        , test "edit init maps product detail into form rows" <|
            \_ ->
                Form.fromProductDetail product
                    |> (\form ->
                            { name = form.name
                            , brand = form.brand
                            , categories = form.categories
                            , nutrients = form.nutrients
                            , servings = form.servings
                            }
                       )
                    |> Expect.equal
                        { name = "Curd"
                        , brand = "Local"
                        , categories = "dairy"
                        , nutrients = [ { code = "PROTEIN_G", amountPer100g = "3.5" } ]
                        , servings =
                            [ { label = "cup"
                              , quantity = "1"
                              , unit = "cup"
                              , grams = "245"
                              }
                            ]
                        }
        , test "remove nutrient keeps at least one row" <|
            \_ ->
                Form.update (Form.RemoveNutrientRow 0) Form.emptyForm
                    |> .nutrients
                    |> List.length
                    |> Expect.equal 1
        ]


product : ProductDetail
product =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Curd"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "cup"
    , servingSizeG = Just "245"
    , nutrients =
        [ { code = "PROTEIN_G"
          , amountPer100g = "3.5"
          , unit = "g"
          , source = Nothing
          , confidence = Nothing
          }
        ]
    , servings = [ { label = "cup", quantity = "1", unit = "cup", grams = "245" } ]
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
