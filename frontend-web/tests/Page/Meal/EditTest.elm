module Page.Meal.EditTest exposing (tests)

import Api.Client as Client
import Api.Meals exposing (Meal, MealNutritionResponse)
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Edit as MealEdit
import Page.Meal.Form as Common
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Form.Edit"
        [ test "init is loading and requests meal" <|
            \_ ->
                MealEdit.init "meal-1"
                    |> Tuple.second
                    |> Expect.equal (MealEdit.RequestMeal "meal-1")
        , test "init starts with loading nutrition state" <|
            \_ ->
                MealEdit.init "meal-1"
                    |> Tuple.first
                    |> nutritionOf
                    |> Expect.equal (Just (NutritionLoading View.Nutrients.defaultNutritionInput))
        , test "meal load success stores meal and maps components into rows" <|
            \_ ->
                MealEdit.update
                    (MealEdit.MealLoaded (Ok meal))
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> first
                    |> componentsOf
                    |> List.map (\row -> ( row.productId, row.quantity, row.unit ))
                    |> Expect.equal [ ( "food-1", "2", "serving" ) ]
        , test "meal load requests the name of its first product component" <|
            \_ ->
                MealEdit.update
                    (MealEdit.MealLoaded (Ok meal))
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> third
                    |> Expect.equal
                        (MealEdit.FormOutMsg (Common.RequestProductName "food-1"))
        , test "meal load failure transitions to edit load failed" <|
            \_ ->
                MealEdit.update
                    (MealEdit.MealLoaded
                        (Err Client.NetworkError)
                    )
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> first
                    |> (\model ->
                            case model of
                                MealEdit.EditLoadFailed message ->
                                    Just message

                                _ ->
                                    Nothing
                       )
                    |> Expect.equal (Just "Network error")
        , test "nutrient preview response stores nutrients" <|
            \_ ->
                MealEdit.update
                    (MealEdit.NutrientPreviewLoaded (Ok nutrientPreview))
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> first
                    |> nutrientsOf
                    |> Expect.equal (Just [ nutrient ])
        , test "submit dispatches update meal with meal id" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1
                in
                MealEdit.update
                    MealEdit.SubmitClicked
                    (loadedWithForm
                        { emptyFormFields
                            | name = "Lunch"
                            , components =
                                [ { row
                                    | productId = "food-1"
                                    , quantity = "2"
                                    , unit = "serving"
                                  }
                                ]
                        }
                    )
                    |> third
                    |> Expect.equal
                        (MealEdit.RequestUpdateMeal "meal-1"
                            { name = "Lunch"
                            , notes = Nothing
                            , totalQuantity = Nothing
                            , components =
                                [ { item = { itemType = ItemRef.Product, id = "food-1" }
                                  , quantity = { amount = "2", unit = "serving" }
                                  }
                                ]
                            }
                        )
        , test "submit with no name surfaces a name-required error" <|
            \_ ->
                MealEdit.update
                    MealEdit.SubmitClicked
                    (loadedWithForm emptyFormFields)
                    |> first
                    |> (\model ->
                            case model of
                                MealEdit.Editing loaded ->
                                    Common.submitErrorMessage loaded.fields.submit

                                _ ->
                                    Nothing
                       )
                    |> Expect.equal (Just "Name is required")
        , test "save success navigates to meal detail" <|
            \_ ->
                MealEdit.update
                    (MealEdit.SaveCompleted (Ok meal))
                    (loadedWithForm emptyFormFields)
                    |> third
                    |> Expect.equal (MealEdit.Navigate (MealShow "meal-1"))
        ]


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


nutrientPreview : MealNutritionResponse
nutrientPreview =
    { mealId = "meal-1"
    , quantity = { amount = "100", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = [ nutrient ]
    }


emptyFormFields : Common.FormFields
emptyFormFields =
    Common.emptyFormFields


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


loadedWithForm : Common.FormFields -> MealEdit.Model
loadedWithForm fields =
    MealEdit.Editing
        { mealId = "meal-1"
        , meal = meal
        , fields = fields
        , nutrition = NutritionLoading View.Nutrients.defaultNutritionInput
        }


componentsOf : MealEdit.Model -> List Common.ComponentRow
componentsOf model =
    case model of
        MealEdit.Editing loaded ->
            loaded.fields.components

        _ ->
            []


nutrientsOf : MealEdit.Model -> Maybe (List NutrientAmount)
nutrientsOf model =
    case model of
        MealEdit.Editing loaded ->
            case loaded.nutrition of
                NutritionLoaded _ nutrients ->
                    Just nutrients

                _ ->
                    Nothing

        MealEdit.LoadingEdit loading ->
            case loading.nutrition of
                NutritionLoaded _ nutrients ->
                    Just nutrients

                _ ->
                    Nothing

        _ ->
            Nothing


nutritionOf : MealEdit.Model -> Maybe NutritionState
nutritionOf model =
    case model of
        MealEdit.LoadingEdit loading ->
            Just loading.nutrition

        MealEdit.Editing loaded ->
            Just loaded.nutrition

        MealEdit.EditLoadFailed _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
