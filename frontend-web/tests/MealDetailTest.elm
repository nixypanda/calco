module MealDetailTest exposing (tests)

import Api.Meals exposing (Meal)
import Data.Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Detail as MealDetail
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Detail"
        [ test "meal load success stores meal" <|
            \_ ->
                MealDetail.update
                    (MealDetail.MealLoaded (Ok meal))
                    (Tuple.first (MealDetail.init "meal-1"))
                    |> first
                    |> .meal
                    |> Maybe.map .id
                    |> Expect.equal (Just "meal-1")
        , test "component product ids are extracted uniquely" <|
            \_ ->
                MealDetail.uniqueProductIds
                    { meal | components = meal.components ++ meal.components }
                    |> Expect.equal [ "food-1" ]
        , test "init requests initial meal data" <|
            \_ ->
                MealDetail.init "meal-1"
                    |> Tuple.second
                    |> Expect.equal (MealDetail.RequestInitialData "meal-1")
        , test "nutrient preview response stores nutrients" <|
            \_ ->
                MealDetail.update
                    (MealDetail.NutrientPreviewLoaded (Ok nutrientPreview))
                    baseModel
                    |> first
                    |> .nutrients
                    |> Expect.equal (Just [ nutrient ])
        , test "amount changes request nutrient preview" <|
            \_ ->
                MealDetail.update
                    (MealDetail.AmountChanged "150")
                    baseModel
                    |> third
                    |> Expect.equal (MealDetail.RequestNutrientPreview "meal-1" "150" "g")
        , test "invalid amount clears nutrient preview" <|
            \_ ->
                MealDetail.update
                    (MealDetail.AmountChanged "nope")
                    { baseModel
                        | nutrients = Just [ nutrient ]
                        , nutritionError = Just "old error"
                        , nutritionLoading = True
                    }
                    |> first
                    |> (\model -> ( model.nutrients, model.nutritionError, model.nutritionLoading ))
                    |> Expect.equal ( Nothing, Nothing, False )
        , test "delete confirmation opens and closes" <|
            \_ ->
                MealDetail.update MealDetail.DeleteClicked baseModel
                    |> first
                    |> MealDetail.update MealDetail.CancelDeleteClicked
                    |> first
                    |> .confirmDeleteOpen
                    |> Expect.equal False
        , test "edit action navigates to meal edit" <|
            \_ ->
                MealDetail.update MealDetail.EditClicked baseModel
                    |> third
                    |> Expect.equal (MealDetail.Navigate (MealEdit "meal-1"))
        ]


baseModel : MealDetail.Model
baseModel =
    Tuple.first (MealDetail.init "meal-1")


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


meal : Meal
meal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { id = "component-1"
          , item = { itemType = "product", id = "food-1" }
          , quantity = { amount = "100", unit = "g" }
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
