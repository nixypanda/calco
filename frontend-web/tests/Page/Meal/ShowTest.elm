module Page.Meal.ShowTest exposing (tests)

import Api.Meals exposing (Meal)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Show as MealShow
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Show"
        [ test "meal load success stores meal" <|
            \_ ->
                MealShow.update
                    (MealShow.MealLoaded (Ok meal))
                    (Tuple.first (MealShow.init "meal-1"))
                    |> first
                    |> mealIdOf
                    |> Expect.equal (Just "meal-1")
        , test "component product ids are extracted uniquely" <|
            \_ ->
                MealShow.uniqueProductIds
                    { meal | components = meal.components ++ meal.components }
                    |> Expect.equal [ "food-1" ]
        , test "init requests initial meal data" <|
            \_ ->
                MealShow.init "meal-1"
                    |> Tuple.second
                    |> Expect.equal (MealShow.RequestInitialData "meal-1")
        , test "nutrient preview response stores nutrients" <|
            \_ ->
                MealShow.update
                    (MealShow.NutrientPreviewLoaded (Ok nutrientPreview))
                    baseModel
                    |> first
                    |> nutrientsOf
                    |> Expect.equal (Just [ nutrient ])
        , test "amount changes request nutrient preview" <|
            \_ ->
                MealShow.update
                    (MealShow.AmountChanged "150")
                    loadedModel
                    |> third
                    |> Expect.equal (MealShow.RequestNutrientPreview "meal-1" "150" "g")
        , test "invalid amount clears nutrient preview" <|
            \_ ->
                MealShow.update
                    (MealShow.AmountChanged "nope")
                    nutritionLoadedModel
                    |> first
                    |> (\model ->
                            ( nutrientsOf model
                            , nutritionErrorOf model
                            , nutritionLoadingOf model
                            )
                       )
                    |> Expect.equal ( Nothing, Nothing, False )
        , test "delete confirmation opens and closes" <|
            \_ ->
                MealShow.update MealShow.DeleteClicked loadedModel
                    |> first
                    |> MealShow.update MealShow.CancelDeleteClicked
                    |> first
                    |> deleteOf
                    |> Expect.equal (Just MealShow.DeleteIdle)
        , test "edit action navigates to meal edit" <|
            \_ ->
                MealShow.update MealShow.EditClicked loadedModel
                    |> third
                    |> Expect.equal (MealShow.Navigate (MealEdit "meal-1"))
        ]


baseModel : MealShow.Model
baseModel =
    Tuple.first (MealShow.init "meal-1")


loadedModel : MealShow.Model
loadedModel =
    MealShow.Loaded
        { mealId = "meal-1"
        , meal = meal
        , productNames = ItemNameLookup.empty
        , units = [ { code = "g", name = "Gram", kind = "mass" } ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = MealShow.DeleteIdle
        }


nutritionLoadedModel : MealShow.Model
nutritionLoadedModel =
    MealShow.Loaded
        { mealId = "meal-1"
        , meal = meal
        , productNames = ItemNameLookup.empty
        , units = [ { code = "g", name = "Gram", kind = "mass" } ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = MealShow.DeleteIdle
        }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


nutrientPreview :
    { mealId : String
    , nutritionSummary : Nutrition.NutritionSummary
    , nutrients : List NutrientAmount
    , quantity : { amount : String, unit : String }
    }
nutrientPreview =
    { mealId = "meal-1"
    , quantity = { amount = "100", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = [ nutrient ]
    }


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
          , quantity = { amount = "100", unit = "g" }
          , nutritionSummary = Nothing
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


mealIdOf : MealShow.Model -> Maybe String
mealIdOf model =
    case model of
        MealShow.Loaded loaded ->
            Just loaded.meal.id

        _ ->
            Nothing


nutrientsOf : MealShow.Model -> Maybe (List NutrientAmount)
nutrientsOf model =
    case model of
        MealShow.Loading loading ->
            nutrientsFromState loading.nutrition

        MealShow.Loaded loaded ->
            nutrientsFromState loaded.nutrition

        MealShow.LoadFailed _ ->
            Nothing


nutritionErrorOf : MealShow.Model -> Maybe String
nutritionErrorOf model =
    case model of
        MealShow.Loading loading ->
            errorFromState loading.nutrition

        MealShow.Loaded loaded ->
            errorFromState loaded.nutrition

        MealShow.LoadFailed _ ->
            Nothing


nutritionLoadingOf : MealShow.Model -> Bool
nutritionLoadingOf model =
    case model of
        MealShow.Loading loading ->
            isLoadingState loading.nutrition

        MealShow.Loaded loaded ->
            isLoadingState loaded.nutrition

        MealShow.LoadFailed _ ->
            False


deleteOf : MealShow.Model -> Maybe MealShow.DeleteState
deleteOf model =
    case model of
        MealShow.Loaded loaded ->
            Just loaded.delete

        _ ->
            Nothing


nutrientsFromState : NutritionState -> Maybe (List NutrientAmount)
nutrientsFromState nutrition =
    case nutrition of
        NutritionLoaded _ nutrients ->
            Just nutrients

        _ ->
            Nothing


errorFromState : NutritionState -> Maybe String
errorFromState nutrition =
    case nutrition of
        NutritionFailed _ message ->
            Just message

        _ ->
            Nothing


isLoadingState : NutritionState -> Bool
isLoadingState nutrition =
    case nutrition of
        NutritionLoading _ ->
            True

        _ ->
            False
