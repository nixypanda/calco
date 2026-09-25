module Component.FoodEditorTest exposing (tests)

import Api.Foods exposing (NutrientItem)
import Component.FoodEditor as Form
import Data.FoodAssistant exposing (FoodDraft)
import Expect
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
                Form.toCreateFoodRequest
                    { emptyForm
                        | name = "Paneer"
                        , nutrients =
                            [ { code = "ENERGY_KCAL"
                              , amount = "abc"
                              , unit = "kcal"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidNutrientAmount "abc"))
        , test "non-positive serving grams per unit is rejected" <|
            \_ ->
                Form.toCreateFoodRequest
                    { emptyForm
                        | name = "Paneer"
                        , servings =
                            [ { unit = "piece"
                              , gramsPerUnit = "0"
                              }
                            ]
                    }
                    |> Expect.equal (Err (Form.InvalidServingGrams "0"))
        , test "duplicate serving units are rejected" <|
            \_ ->
                Form.toCreateFoodRequest
                    { emptyForm
                        | name = "Soup"
                        , servings =
                            [ { unit = "cup", gramsPerUnit = "180" }
                            , { unit = "cup", gramsPerUnit = "360" }
                            ]
                    }
                    |> Expect.equal (Err (Form.DuplicateServingUnit "cup"))
        , test "initial create payload discards portions and servings" <|
            \_ ->
                Form.toInitialCreateFoodRequest
                    { emptyForm
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
        , test "payload trims fields, filters incomplete rows, and adds categories" <|
            \_ ->
                let
                    base : Form.FormModel
                    base =
                        updateForm (Form.AddCategory "Dairy") Form.emptyForm
                in
                Form.toCreateFoodRequest
                    { base
                        | name = "  Paneer  "
                        , brand = " "
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
        , test "addCategoryTag normalizes and dedupes" <|
            \_ ->
                Form.addCategoryTag "  Fruit " [ "snack" ]
                    |> Expect.equal [ "snack", "fruit" ]
        , test "a nutrient catalog load backfills units and code changes resolve or clear them" <|
            \_ ->
                let
                    loaded : Form.FormModel
                    loaded =
                        updateForm
                            (Form.NutrientsLoaded nutrientItems)
                            { emptyForm
                                | nutrients =
                                    [ { code = "PROTEIN_G"
                                      , amount = "18"
                                      , unit = ""
                                      }
                                    ]
                            }

                    resolved : Form.FormModel
                    resolved =
                        updateForm (Form.NutrientCodeChanged 0 "ENERGY_KCAL") loaded

                    cleared : Form.FormModel
                    cleared =
                        updateForm (Form.NutrientCodeChanged 0 "NOT_A_CODE") resolved
                in
                ( unitOf loaded, unitOf resolved, unitOf cleared )
                    |> Expect.equal ( Just "g", Just "kcal", Just "" )
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
                ( Form.hasManualInput emptyForm
                , Form.hasManualInput { emptyForm | name = "Dal" }
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


unitOf : Form.FormModel -> Maybe String
unitOf form =
    form.nutrients |> List.head |> Maybe.map .unit


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
