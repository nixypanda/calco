module Page.Meal.EditTest exposing (tests)

import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Edit as MealEdit
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.Meal.Edit"
        [ test "meal load success stores meal and maps components into rows" <|
            \_ ->
                MealEdit.update
                    (MealEdit.MealLoaded "meal-1" (Ok meal))
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> first
                    |> componentsOf
                    |> List.map (\row -> ( row.productId, row.quantity, row.unit ))
                    |> Expect.equal [ ( "food-1", "2", "serving" ) ]
        , test "meal load requests the name of its first product component" <|
            \_ ->
                MealEdit.update
                    (MealEdit.MealLoaded "meal-1" (Ok meal))
                    (Tuple.first (MealEdit.init "meal-1"))
                    |> third
                    |> Expect.equal
                        (MealEdit.FormOutMsg (Common.RequestProductName "food-1"))
        , test "retry from edit load failed requests the meal again" <|
            \_ ->
                let
                    ( model, _, outMsg ) =
                        MealEdit.update MealEdit.RetryClicked
                            (MealEdit.EditLoadFailed
                                { mealId = "meal-1"
                                , message = networkErrorMessage
                                }
                            )
                in
                case model of
                    MealEdit.LoadingEdit loading ->
                        ( loading.mealId, outMsg )
                            |> Expect.equal ( "meal-1", MealEdit.RequestMeal "meal-1" )

                    _ ->
                        Expect.fail "expected LoadingEdit"
        , test "a load response for another meal is ignored" <|
            \_ ->
                let
                    base : MealEdit.Model
                    base =
                        Tuple.first (MealEdit.init "meal-1")
                in
                MealEdit.update (MealEdit.MealLoaded "other" (Ok meal)) base
                    |> first
                    |> Expect.equal base
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


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
