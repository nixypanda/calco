module MealDetailTest exposing (tests)

import Api.Meals exposing (Meal)
import Data.ItemNameLookup as ItemNameLookup
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Detail as MealDetail
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Detail"
        [ test "meal load success stores meal" <|
            \_ ->
                MealDetail.update
                    (MealDetail.MealLoaded (Ok meal))
                    (Tuple.first (MealDetail.init "meal-1"))
                    |> first
                    |> mealIdOf
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
                    |> nutrientsOf
                    |> Expect.equal (Just [ nutrient ])
        , test "amount changes request nutrient preview" <|
            \_ ->
                MealDetail.update
                    (MealDetail.AmountChanged "150")
                    loadedModel
                    |> third
                    |> Expect.equal (MealDetail.RequestNutrientPreview "meal-1" "150" "g")
        , test "invalid amount clears nutrient preview" <|
            \_ ->
                MealDetail.update
                    (MealDetail.AmountChanged "nope")
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
                MealDetail.update MealDetail.DeleteClicked loadedModel
                    |> first
                    |> MealDetail.update MealDetail.CancelDeleteClicked
                    |> first
                    |> deleteOf
                    |> Expect.equal (Just MealDetail.DeleteIdle)
        , test "edit action navigates to meal edit" <|
            \_ ->
                MealDetail.update MealDetail.EditClicked loadedModel
                    |> third
                    |> Expect.equal (MealDetail.Navigate (MealEdit "meal-1"))
        ]


baseModel : MealDetail.Model
baseModel =
    Tuple.first (MealDetail.init "meal-1")


loadedModel : MealDetail.Model
loadedModel =
    MealDetail.Loaded
        { mealId = "meal-1"
        , meal = meal
        , productNames = ItemNameLookup.empty
        , units = [ { code = "g", name = "Gram", kind = "mass" } ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = MealDetail.DeleteIdle
        }


nutritionLoadedModel : MealDetail.Model
nutritionLoadedModel =
    MealDetail.Loaded
        { mealId = "meal-1"
        , meal = meal
        , productNames = ItemNameLookup.empty
        , units = [ { code = "g", name = "Gram", kind = "mass" } ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = MealDetail.DeleteIdle
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
          , item = { itemType = "product", id = "food-1" }
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


mealIdOf : MealDetail.Model -> Maybe String
mealIdOf model =
    case model of
        MealDetail.Loaded loaded ->
            Just loaded.meal.id

        _ ->
            Nothing


nutrientsOf : MealDetail.Model -> Maybe (List NutrientAmount)
nutrientsOf model =
    case model of
        MealDetail.Loading loading ->
            nutrientsFromState loading.nutrition

        MealDetail.Loaded loaded ->
            nutrientsFromState loaded.nutrition

        MealDetail.LoadFailed _ ->
            Nothing


nutritionErrorOf : MealDetail.Model -> Maybe String
nutritionErrorOf model =
    case model of
        MealDetail.Loading loading ->
            errorFromState loading.nutrition

        MealDetail.Loaded loaded ->
            errorFromState loaded.nutrition

        MealDetail.LoadFailed _ ->
            Nothing


nutritionLoadingOf : MealDetail.Model -> Bool
nutritionLoadingOf model =
    case model of
        MealDetail.Loading loading ->
            isLoadingState loading.nutrition

        MealDetail.Loaded loaded ->
            isLoadingState loaded.nutrition

        MealDetail.LoadFailed _ ->
            False


deleteOf : MealDetail.Model -> Maybe MealDetail.DeleteState
deleteOf model =
    case model of
        MealDetail.Loaded loaded ->
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
