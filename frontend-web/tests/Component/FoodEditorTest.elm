module Component.FoodEditorTest exposing (tests)

import Api.Foods exposing (NutrientItem, ProductDetail, UnitItem)
import Component.FoodEditor as Form
import Data.FoodAssistant exposing (FoodDraft)
import Data.Nutrition as Nutrition
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Component.FoodEditor custom-food mode"
        [ test "name is required" <|
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
                              , amount = "abc"
                              , unit = "kcal"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidNutrientAmount "abc"))
        , test "initial create payload discards portions and servings" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toInitialCreateFoodRequest
                    { base
                        | name = "Paneer"
                        , defaultQuantity = "1"
                        , defaultUnit = "piece"
                        , servings = [ { unit = "piece", gramsPerUnit = "50" } ]
                    }
                    |> Result.map
                        (\request ->
                            ( request.defaultQuantity
                            , request.defaultUnit
                            , request.servings
                            )
                        )
                    |> Expect.equal (Ok ( Nothing, Nothing, [] ))
        , test "non-positive serving grams per unit is rejected" <|
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
                            [ { unit = "piece"
                              , gramsPerUnit = "0"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidServingGrams "0"))
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
                        , defaultQuantity = ""
                        , categoryInput =
                            { selected = [ "dairy" ]
                            , query = ""
                            , suggestions = []
                            , token = ticket 0
                            }
                        , nutrients =
                            [ { code = "PROTEIN_G"
                              , amount = "18"
                              , unit = "g"
                              }
                            , { code = ""
                              , amount = "4"
                              , unit = "g"
                              }
                            ]
                        , servings =
                            [ { unit = "piece"
                              , gramsPerUnit = "50"
                              }
                            , { unit = ""
                              , gramsPerUnit = "5"
                              }
                            ]
                    }
                    |> Result.map
                        (\request ->
                            { name = request.name
                            , brand = request.brand
                            , categories = request.categories
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
                            , defaultQuantity = Nothing
                            , nutrients =
                                [ { code = "PROTEIN_G", amountPer100g = 18 } ]
                            , servings =
                                [ { unit = "piece"
                                  , gramsPerUnit = 50
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
                              , amount = "3.5"
                              , unit = "g"
                              }
                            ]
                        , servings =
                            [ { unit = "cup"
                              , gramsPerUnit = "245.124"
                              }
                            ]
                        }
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
                        Form.update (Form.NutrientCodeChanged 0 "PROTEIN_G") afterLoad
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
                                  , amount = "18"
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
        , test "NutrientCodeChanged with unknown code clears unit" <|
            \_ ->
                let
                    ( afterCode, _, _ ) =
                        Form.update
                            (Form.NutrientCodeChanged 0 "NOT_A_CODE")
                            Form.emptyForm
                in
                afterCode.nutrients
                    |> List.head
                    |> Maybe.map .unit
                    |> Expect.equal (Just "")
        , test "add category updates selected categories and clears query" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        { emptyForm
                            | categoryInput =
                                { selected = []
                                , query = "Dairy"
                                , suggestions = [ { value = "dairy", count = 3 } ]
                                , token = ticket 0
                                }
                        }
                in
                Form.update (Form.AddCategory "Dairy") base
                    |> first
                    |> .categoryInput
                    |> (\input -> ( input.selected, input.query, input.suggestions ))
                    |> Expect.equal ( [ "dairy" ], "", [] )
        , test "remove category removes only matching value" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        { emptyForm
                            | categoryInput =
                                { selected = [ "dairy", "snack" ]
                                , query = ""
                                , suggestions = []
                                , token = ticket 0
                                }
                        }
                in
                Form.update (Form.RemoveCategory "dairy") base
                    |> first
                    |> .categoryInput
                    |> .selected
                    |> Expect.equal [ "snack" ]
        , test "matching category suggestions are stored" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        { emptyForm
                            | categoryInput =
                                { selected = []
                                , query = "dai"
                                , suggestions = []
                                , token = ticket 1
                                }
                        }
                in
                Form.update
                    (Form.CategorySuggestionsLoaded
                        (ticket 1)
                        (Ok [ { value = "dairy", count = 3 } ])
                    )
                    base
                    |> first
                    |> .categoryInput
                    |> .suggestions
                    |> Expect.equal [ { value = "dairy", count = 3 } ]
        , test "stale category suggestions are ignored" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        { emptyForm
                            | categoryInput =
                                { selected = []
                                , query = "dai"
                                , suggestions = [ { value = "old", count = 1 } ]
                                , token = ticket 2
                                }
                        }
                in
                Form.update
                    (Form.CategorySuggestionsLoaded
                        (ticket 1)
                        (Ok [ { value = "dairy", count = 3 } ])
                    )
                    base
                    |> first
                    |> .categoryInput
                    |> .suggestions
                    |> Expect.equal [ { value = "old", count = 1 } ]
        , test "add and remove nutrient row removes selected extra row" <|
            \_ ->
                Form.emptyForm
                    |> updateForm Form.AddNutrientRow
                    |> updateForm (Form.NutrientAmountChanged 1 "12")
                    |> updateForm (Form.RemoveNutrientRow 0)
                    |> .nutrients
                    |> List.map .amount
                    |> Expect.equal [ "12" ]
        , test "serving row messages update and remove rows" <|
            \_ ->
                Form.emptyForm
                    |> updateForm Form.AddServingRow
                    |> updateForm (Form.ServingUnitChanged 0 "piece")
                    |> updateForm (Form.ServingGramsPerUnitChanged 0 "50")
                    |> .servings
                    |> Expect.equal
                        [ { unit = "piece"
                          , gramsPerUnit = "50"
                          }
                        ]
        , test "remove serving row removes the selected row" <|
            \_ ->
                Form.emptyForm
                    |> updateForm Form.AddServingRow
                    |> updateForm Form.AddServingRow
                    |> updateForm (Form.ServingUnitChanged 1 "second")
                    |> updateForm (Form.RemoveServingRow 0)
                    |> .servings
                    |> List.map .unit
                    |> Expect.equal [ "second" ]
        , test "no default option clears the selected default without staying selected" <|
            \_ ->
                Form.emptyForm
                    |> updateForm (Form.DefaultUnitChanged "g")
                    |> updateForm (Form.DefaultUnitChanged "__no_default__")
                    |> (\form -> ( form.defaultQuantity, form.defaultUnit ))
                    |> Expect.equal ( "", "" )
        , test "removing the selected serving clears the default portion" <|
            \_ ->
                Form.emptyForm
                    |> updateForm Form.AddServingRow
                    |> updateForm (Form.ServingUnitChanged 0 "cup")
                    |> updateForm (Form.DefaultUnitChanged "cup")
                    |> updateForm (Form.RemoveServingRow 0)
                    |> (\form -> ( form.defaultQuantity, form.defaultUnit ))
                    |> Expect.equal ( "", "" )
        , test "duplicate serving units are rejected" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "Soup"
                        , servings =
                            [ { unit = "cup", gramsPerUnit = "180" }
                            , { unit = "cup", gramsPerUnit = "360" }
                            ]
                    }
                    |> Expect.equal (Err (Form.DuplicateServingUnit "cup"))
        , test "AI draft maps every value without changing decimal text" <|
            \_ ->
                Form.emptyForm
                    |> Form.withNutrientCatalog nutrientItems
                    |> Form.applyAiDraft assistantDraft
                    |> (\form ->
                            { name = form.name
                            , brand = form.brand
                            , categories = form.categoryInput.selected
                            , defaultQuantity = form.defaultQuantity
                            , defaultUnit = form.defaultUnit
                            , nutrients = form.nutrients
                            , servings = form.servings
                            }
                       )
                    |> Expect.equal
                        { name = "Dal"
                        , brand = "Kitchen"
                        , categories = [ "lentils", "dinner" ]
                        , defaultQuantity = "1"
                        , defaultUnit = "bowl"
                        , nutrients =
                            [ { code = "ENERGY_KCAL"
                              , amount = "120.125000"
                              , unit = "kcal"
                              }
                            ]
                        , servings =
                            [ { unit = "bowl"
                              , gramsPerUnit = "300.50"
                              }
                            ]
                        }
        , test "manual input detection ignores the blank starter row" <|
            \_ ->
                let
                    empty : Form.FormModel
                    empty =
                        Form.emptyForm
                in
                ( Form.hasManualInput empty
                , Form.hasManualInput { empty | name = "Dal" }
                )
                    |> Expect.equal ( False, True )
        ]


assistantDraft : FoodDraft
assistantDraft =
    { name = "Dal"
    , brand = Just "Kitchen"
    , categories = [ "Lentils", "DINNER" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "bowl"
    , nutrients =
        [ { code = "ENERGY_KCAL", amountPer100g = "120.125000" } ]
    , servings =
        [ { unit = "bowl"
          , gramsPerUnit = "300.50"
          }
        ]
    }


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
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients =
        [ { code = "PROTEIN_G"
          , amountPer100g = "3.5"
          , unit = "g"
          , source = Nothing
          , confidence = Nothing
          }
        ]
    , servings = [ { unit = "cup", gramsPerUnit = "245.1236000000" } ]
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


emptyForm : Form.FormModel
emptyForm =
    Form.emptyForm


updateForm : Form.Msg -> Form.FormModel -> Form.FormModel
updateForm msg form =
    Form.update msg form
        |> first


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
