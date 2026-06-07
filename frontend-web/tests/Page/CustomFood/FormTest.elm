module Page.CustomFood.FormTest exposing (tests)

import Api.Foods exposing (NutrientItem, ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Expect
import Page.CustomFood.Form as Form
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Form"
        [ test "empty form has one nutrient row" <|
            \_ ->
                Form.emptyForm.nutrients
                    |> List.length
                    |> Expect.equal 1
        , test "name is required" <|
            \_ ->
                Form.toCreateFoodRequest Form.emptyForm
                    |> Expect.equal (Err Form.NameRequired)
        , test "non-numeric nutrient amount is rejected" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "Paneer"
                        , nutrients =
                            [ { code = "ENERGY_KCAL"
                              , amountPer100g = "abc"
                              , unit = "kcal"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidNutrientAmount "abc"))
        , test "negative nutrient amount is rejected" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "Paneer"
                        , nutrients =
                            [ { code = "ENERGY_KCAL"
                              , amountPer100g = "-1"
                              , unit = "kcal"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidNutrientAmount "-1"))
        , test "non-positive serving quantity is rejected" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "Paneer"
                        , servings =
                            [ { label = "cube"
                              , quantity = "0"
                              , unit = "piece"
                              , grams = "50"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidServingQuantity "0"))
        , test "categories are passed through in selection order" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "Paneer"
                        , categoryInput =
                            { selected = [ "snack", "fruit" ]
                            , query = ""
                            , suggestions = []
                            , token = 0
                            }
                    }
                    |> Result.map .categories
                    |> Expect.equal (Ok [ "snack", "fruit" ])
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
                        , categoryInput =
                            { selected = [ "dairy" ]
                            , query = ""
                            , suggestions = []
                            , token = 0
                            }
                        , nutrients =
                            [ { code = "PROTEIN_G"
                              , amountPer100g = "18"
                              , unit = "g"
                              }
                            , { code = ""
                              , amountPer100g = "4"
                              , unit = "g"
                              }
                            ]
                        , servings =
                            [ { label = "cube"
                              , quantity = "2"
                              , unit = "piece"
                              , grams = "50"
                              }
                            , { label = "bad"
                              , quantity = ""
                              , unit = "g"
                              , grams = "5"
                              }
                            ]
                    }
                    |> Result.map
                        (\request ->
                            { name = request.name
                            , brand = request.brand
                            , categories = request.categories
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
                            , categories = [ "dairy" ]
                            , servingSizeG = Nothing
                            , defaultQuantity = Nothing
                            , nutrients =
                                [ { code = "PROTEIN_G", amountPer100g = 18 } ]
                            , servings =
                                [ { label = "cube"
                                  , quantity = 2
                                  , unit = "piece"
                                  , grams = 50
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
                            , categories = form.categoryInput.selected
                            , nutrients = form.nutrients
                            , servings = form.servings
                            }
                       )
                    |> Expect.equal
                        { name = "Curd"
                        , brand = "Local"
                        , categories = [ "dairy" ]
                        , nutrients =
                            [ { code = "PROTEIN_G"
                              , amountPer100g = "3.5"
                              , unit = "g"
                              }
                            ]
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
                let
                    ( form, _, _ ) =
                        Form.update (Form.RemoveNutrientRow 0) Form.emptyForm
                in
                form.nutrients
                    |> List.length
                    |> Expect.equal 1
        , test "addCategoryTag normalizes and dedupes" <|
            \_ ->
                Form.addCategoryTag "  Fruit " [ "snack" ]
                    |> Expect.equal [ "snack", "fruit" ]
        , test "update returns outmsg to request suggestions" <|
            \_ ->
                let
                    ( _, _, out ) =
                        Form.update (Form.CategoryQueryChanged "dai") Form.emptyForm
                in
                case out of
                    Form.RequestCategorySuggestions _ _ ->
                        Expect.pass

                    Form.NoOutMsg ->
                        Expect.fail "expected RequestCategorySuggestions"
        , test "NutrientsLoaded seeds catalog and code change resolves unit" <|
            \_ ->
                let
                    items : List NutrientItem
                    items =
                        [ { code = "ENERGY_KCAL"
                          , name = "Energy"
                          , unit = "kcal"
                          , category = "energy"
                          }
                        , { code = "PROTEIN_G"
                          , name = "Protein"
                          , unit = "g"
                          , category = "macros"
                          }
                        ]

                    ( afterLoad, _, _ ) =
                        Form.update (Form.NutrientsLoaded items) Form.emptyForm

                    ( afterCode, _, _ ) =
                        Form.update (Form.NutrientCodeChanged 0 "PROTEIN_G" "g") afterLoad
                in
                afterCode.nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "g")
        , test "NutrientsLoaded backfills blank unit for selected row" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm

                    formWithCode : Form.FormModel
                    formWithCode =
                        { base
                            | nutrients =
                                [ { code = "PROTEIN_G"
                                  , amountPer100g = "18"
                                  , unit = ""
                                  }
                                ]
                        }

                    ( afterLoad, _, _ ) =
                        Form.update (Form.NutrientsLoaded nutrientItems) formWithCode
                in
                afterLoad.nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "g")
        , test "NutrientsLoaded keeps existing populated unit" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm

                    formWithUnit : Form.FormModel
                    formWithUnit =
                        { base
                            | nutrients =
                                [ { code = "PROTEIN_G"
                                  , amountPer100g = "18"
                                  , unit = "custom"
                                  }
                                ]
                        }

                    ( afterLoad, _, _ ) =
                        Form.update (Form.NutrientsLoaded nutrientItems) formWithUnit
                in
                afterLoad.nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "custom")
        , test "NutrientCodeChanged with unknown code clears unit" <|
            \_ ->
                let
                    ( afterCode, _, _ ) =
                        Form.update
                            (Form.NutrientCodeChanged 0 "NOT_A_CODE" "")
                            Form.emptyForm
                in
                afterCode.nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "")
        , test "padUnitLabel fills 4-char column with 'none' for empty" <|
            \_ ->
                Form.padUnitLabel ""
                    |> Expect.equal "none"
        , test "padUnitLabel left-pads short units" <|
            \_ ->
                Form.padUnitLabel "g"
                    |> Expect.equal "g   "
        , test "padUnitLabel keeps 4-char units as-is" <|
            \_ ->
                Form.padUnitLabel "kcal"
                    |> Expect.equal "kcal"
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
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
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


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "ENERGY_KCAL"
      , name = "Energy"
      , unit = "kcal"
      , category = "energy"
      }
    , { code = "PROTEIN_G"
      , name = "Protein"
      , unit = "g"
      , category = "macros"
      }
    ]
