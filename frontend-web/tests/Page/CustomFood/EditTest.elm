module Page.CustomFood.EditTest exposing (tests)

import Api.Foods exposing (NutrientItem, ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Expect
import Page.CustomFood.Edit as CustomFoodEdit
import Page.CustomFood.Form as Form
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Edit"
        [ test "loaded form keeps nutrient unit when food arrives before nutrients" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Tuple.first
                    |> CustomFoodEdit.update (CustomFoodEdit.FoodLoaded (Ok food))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.FormMsg
                            (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                        )
                    |> first
                    |> firstNutrientUnit
                    |> Expect.equal (Just "g")
        , test "loaded form keeps nutrient unit when food arrives last" <|
            \_ ->
                CustomFoodEdit.init "food-1"
                    |> Tuple.first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> CustomFoodEdit.update (CustomFoodEdit.FoodLoaded (Ok food))
                    |> first
                    |> CustomFoodEdit.update
                        (CustomFoodEdit.FormMsg
                            (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                        )
                    |> first
                    |> firstNutrientUnit
                    |> Expect.equal (Just "g")
        ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


firstNutrientUnit : CustomFoodEdit.Model -> Maybe String
firstNutrientUnit model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            loaded.form.nutrients
                |> List.head
                |> Maybe.map .unit

        _ ->
            Nothing


food : ProductDetail
food =
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
    , nutrients = []
    , servings = []
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
    , { code = "MONOUNSATURATED_FAT_G"
      , name = "Monounsaturated Fat"
      , unit = "g"
      , category = "macros"
      }
    ]
