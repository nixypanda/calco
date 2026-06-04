module MealDetailTest exposing (tests)

import Api.Meals exposing (Meal)
import Data.Nutrition exposing (NutrientAmount)
import Expect
import Page.MealDetail as MealDetail
import Route exposing (Route(..))
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.MealDetail"
        [ test "meal load success stores meal" <|
            \_ ->
                MealDetail.update (MealDetail.MealLoaded (Ok meal)) (Tuple.first (MealDetail.init "meal-1"))
                    |> first
                    |> .meal
                    |> Maybe.map .id
                    |> Expect.equal (Just "meal-1")
        , test "component product ids are extracted uniquely" <|
            \_ ->
                MealDetail.uniqueProductIds { meal | components = meal.components ++ meal.components }
                    |> Expect.equal [ "food-1" ]
        , test "invalid log amount clears nutrient preview" <|
            \_ ->
                MealDetail.update (MealDetail.AmountChanged "bad") { baseModel | logForm = { logForm | nutrients = Just [ nutrient ] } }
                    |> first
                    |> .logForm
                    |> .nutrients
                    |> Expect.equal Nothing
        , test "amount change starts a new nutrient preview token" <|
            \_ ->
                MealDetail.update (MealDetail.AmountChanged "200") baseModel
                    |> third
                    |> Expect.equal (MealDetail.RequestNutrientPreview "meal-1" "200" "g" 1)
        , test "matching nutrient preview response stores nutrients" <|
            \_ ->
                MealDetail.update (MealDetail.NutrientPreviewLoaded 1 (Ok { mealId = "meal-1", quantity = { amount = "100", unit = "g" }, nutrients = [ nutrient ] })) { baseModel | logForm = { logForm | previewToken = 1 } }
                    |> first
                    |> .logForm
                    |> .nutrients
                    |> Expect.equal (Just [ nutrient ])
        , test "stale nutrient preview response is ignored" <|
            \_ ->
                MealDetail.update (MealDetail.NutrientPreviewLoaded 1 (Ok { mealId = "meal-1", quantity = { amount = "100", unit = "g" }, nutrients = [ nutrient ] })) { baseModel | logForm = { logForm | previewToken = 2 } }
                    |> first
                    |> .logForm
                    |> .nutrients
                    |> Expect.equal Nothing
        , test "log meal payload uses meal item type" <|
            \_ ->
                MealDetail.createMealLogRequest "2026-06-04T10:00:00+05:30" "meal-1" logForm
                    |> Result.map .item
                    |> Expect.equal (Ok { itemType = "meal", id = "meal-1" })
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


logForm : MealDetail.LogMealForm
logForm =
    { amount = "100"
    , unit = "g"
    , nutrients = Nothing
    , previewToken = 0
    , previewLoading = False
    , logging = False
    , error = Nothing
    }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


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
