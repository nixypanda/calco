module Page.Meal.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Meals exposing (Meal)
import Data.ItemNameLookup as ItemNameLookup
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Show as MealShow
import Test exposing (Test, describe, test)
import View.DeleteModal exposing (DeleteState(..))
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
        , test "meal load requests first missing product detail" <|
            \_ ->
                MealShow.update
                    (MealShow.MealLoaded (Ok twoProductMeal))
                    (Tuple.first (MealShow.init "meal-1"))
                    |> third
                    |> Expect.equal (MealShow.RequestProductDetail "food-1")
        , test "meal load with no product components requests no-op" <|
            \_ ->
                MealShow.update
                    (MealShow.MealLoaded (Ok mealOnlyMeal))
                    (Tuple.first (MealShow.init "meal-1"))
                    |> third
                    |> Expect.equal MealShow.NoOp
        , test "meal load failure stores error" <|
            \_ ->
                MealShow.update
                    (MealShow.MealLoaded (Err Client.NetworkError))
                    (Tuple.first (MealShow.init "meal-1"))
                    |> first
                    |> Expect.equal (MealShow.LoadFailed "Network error")
        , test "meal load unauthorized expires session" <|
            \_ ->
                MealShow.update
                    (MealShow.MealLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    (Tuple.first (MealShow.init "meal-1"))
                    |> third
                    |> Expect.equal MealShow.SessionExpired
        , test "component product ids are extracted uniquely" <|
            \_ ->
                MealShow.uniqueProductIds
                    { meal | components = meal.components ++ meal.components }
                    |> Expect.equal [ "food-1" ]
        , test "component meal refs are ignored when extracting product ids" <|
            \_ ->
                MealShow.uniqueProductIds mealOnlyMeal
                    |> Expect.equal []
        , test "init requests initial meal data" <|
            \_ ->
                MealShow.init "meal-1"
                    |> Tuple.second
                    |> Expect.equal (MealShow.RequestInitialData "meal-1")
        , test "product detail load stores name and requests next missing product" <|
            \_ ->
                MealShow.update
                    (MealShow.ProductDetailLoaded "food-1" (Ok product))
                    (loadedWithMeal twoProductMeal)
                    |> third
                    |> Expect.equal (MealShow.RequestProductDetail "food-2")
        , test "product detail failure stores unknown name and continues" <|
            \_ ->
                MealShow.update
                    (MealShow.ProductDetailLoaded "food-1" (Err Client.NetworkError))
                    (loadedWithMeal twoProductMeal)
                    |> third
                    |> Expect.equal (MealShow.RequestProductDetail "food-2")
        , test "last product detail load ends request chain" <|
            \_ ->
                MealShow.update
                    (MealShow.ProductDetailLoaded "food-2" (Ok { product | id = "food-2" }))
                    (loadedWithMealAndName twoProductMeal "food-1")
                    |> third
                    |> Expect.equal MealShow.NoOp
        , test "unit load stores units in loading model" <|
            \_ ->
                MealShow.update
                    (MealShow.UnitsLoaded (Ok { items = [ gram ] }))
                    baseModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ gram ])
        , test "unit load stores units in loaded model" <|
            \_ ->
                MealShow.update
                    (MealShow.UnitsLoaded (Ok { items = [ ounce ] }))
                    loadedModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ ounce ])
        , test "empty unit response uses fallback unit" <|
            \_ ->
                MealShow.update
                    (MealShow.UnitsLoaded (Ok { items = [] }))
                    loadedModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ { code = "g", name = "g", kind = "mass" } ])
        , test "unit load failure uses fallback unit" <|
            \_ ->
                MealShow.update
                    (MealShow.UnitsLoaded (Err Client.NetworkError))
                    loadedModel
                    |> first
                    |> unitsOf
                    |> Expect.equal (Just [ { code = "g", name = "g", kind = "mass" } ])
        , test "nutrient preview response stores nutrients" <|
            \_ ->
                MealShow.update
                    (MealShow.NutrientPreviewLoaded (Ok nutrientPreview))
                    baseModel
                    |> first
                    |> nutrientsOf
                    |> Expect.equal (Just [ nutrient ])
        , test "stale nutrient preview response is ignored" <|
            \_ ->
                MealShow.update
                    (MealShow.NutrientPreviewLoaded
                        (Ok
                            { nutrientPreview
                                | quantity = { amount = "200", unit = "g" }
                            }
                        )
                    )
                    loadedModel
                    |> first
                    |> nutrientsOf
                    |> Expect.equal (Just [ nutrient ])
        , test "nutrient preview failure stores error" <|
            \_ ->
                MealShow.update
                    (MealShow.NutrientPreviewLoaded (Err Client.NetworkError))
                    loadedModel
                    |> first
                    |> nutritionErrorOf
                    |> Expect.equal (Just "Network error")
        , test "nutrient preview unauthorized expires session" <|
            \_ ->
                MealShow.update
                    (MealShow.NutrientPreviewLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    loadedModel
                    |> third
                    |> Expect.equal MealShow.SessionExpired
        , test "amount changes request nutrient preview" <|
            \_ ->
                MealShow.update
                    (MealShow.AmountChanged "150")
                    loadedModel
                    |> third
                    |> Expect.equal (MealShow.RequestNutrientPreview "meal-1" "150" "g")
        , test "zero amount clears nutrient preview" <|
            \_ ->
                MealShow.update
                    (MealShow.AmountChanged "0")
                    nutritionLoadedModel
                    |> first
                    |> nutrientsOf
                    |> Expect.equal Nothing
        , test "unit change requests nutrient preview" <|
            \_ ->
                MealShow.update
                    (MealShow.UnitChanged "serving")
                    loadedModel
                    |> third
                    |> Expect.equal (MealShow.RequestNutrientPreview "meal-1" "100" "serving")
        , test "toggle unit dropdown toggles loaded input" <|
            \_ ->
                MealShow.update MealShow.ToggleUnitDropdown loadedModel
                    |> first
                    |> unitOpenOf
                    |> Expect.equal (Just True)
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
                    |> Expect.equal (Just DeleteIdle)
        , test "confirm delete requests deletion from confirming state" <|
            \_ ->
                MealShow.update MealShow.DeleteClicked loadedModel
                    |> first
                    |> MealShow.update MealShow.ConfirmDeleteClicked
                    |> third
                    |> Expect.equal (MealShow.RequestDeleteMeal "meal-1")
        , test "confirm delete retries from failed state" <|
            \_ ->
                MealShow.update
                    MealShow.ConfirmDeleteClicked
                    (loadedWithDelete (DeleteFailed "Try again"))
                    |> third
                    |> Expect.equal (MealShow.RequestDeleteMeal "meal-1")
        , test "confirm delete is ignored from idle state" <|
            \_ ->
                MealShow.update MealShow.ConfirmDeleteClicked loadedModel
                    |> third
                    |> Expect.equal MealShow.NoOp
        , test "delete success navigates to meal list" <|
            \_ ->
                MealShow.update
                    (MealShow.DeleteCompleted (Ok ()))
                    (loadedWithDelete Deleting)
                    |> third
                    |> Expect.equal (MealShow.Navigate MealList)
        , test "delete failure stores delete error" <|
            \_ ->
                MealShow.update
                    (MealShow.DeleteCompleted (Err Client.NetworkError))
                    (loadedWithDelete Deleting)
                    |> first
                    |> deleteOf
                    |> Expect.equal (Just (DeleteFailed "Network error"))
        , test "delete unauthorized expires session" <|
            \_ ->
                MealShow.update
                    (MealShow.DeleteCompleted
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    (loadedWithDelete Deleting)
                    |> third
                    |> Expect.equal MealShow.SessionExpired
        , test "delete completion is ignored unless deleting" <|
            \_ ->
                MealShow.update
                    (MealShow.DeleteCompleted (Ok ()))
                    loadedModel
                    |> third
                    |> Expect.equal MealShow.NoOp
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
    loadedWithMeal meal


nutritionLoadedModel : MealShow.Model
nutritionLoadedModel =
    loadedWithMeal meal


loadedWithMeal : Meal -> MealShow.Model
loadedWithMeal nextMeal =
    MealShow.Loaded
        { mealId = "meal-1"
        , meal = nextMeal
        , productNames = ItemNameLookup.empty
        , units = [ gram ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = DeleteIdle
        }


loadedWithMealAndName : Meal -> String -> MealShow.Model
loadedWithMealAndName nextMeal productId =
    MealShow.Loaded
        { mealId = "meal-1"
        , meal = nextMeal
        , productNames =
            ItemNameLookup.insertProduct
                productId
                "Loaded"
                ItemNameLookup.empty
        , units = [ gram ]
        , nutrition =
            NutritionLoaded
                { amount = "100", unit = "g", unitOpen = False }
                [ nutrient ]
        , delete = DeleteIdle
        }


loadedWithDelete : DeleteState -> MealShow.Model
loadedWithDelete delete =
    case loadedModel of
        MealShow.Loaded loaded ->
            MealShow.Loaded { loaded | delete = delete }

        _ ->
            loadedModel


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


twoProductMeal : Meal
twoProductMeal =
    { meal
        | components =
            meal.components
                ++ [ { id = "component-2"
                     , item = { itemType = ItemRef.Product, id = "food-2" }
                     , quantity = { amount = "50", unit = "g" }
                     , nutritionSummary = Nothing
                     }
                   ]
    }


mealOnlyMeal : Meal
mealOnlyMeal =
    { meal
        | components =
            [ { id = "component-meal"
              , item = { itemType = ItemRef.Meal, id = "meal-child" }
              , quantity = { amount = "1", unit = "serving" }
              , nutritionSummary = Nothing
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
    , name = "Apple"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


ounce : UnitItem
ounce =
    { code = "oz", name = "Ounce", kind = "mass" }


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


deleteOf : MealShow.Model -> Maybe DeleteState
deleteOf model =
    case model of
        MealShow.Loaded loaded ->
            Just loaded.delete

        _ ->
            Nothing


unitsOf : MealShow.Model -> Maybe (List UnitItem)
unitsOf model =
    case model of
        MealShow.Loading loading ->
            Just loading.units

        MealShow.Loaded loaded ->
            Just loaded.units

        MealShow.LoadFailed _ ->
            Nothing


unitOpenOf : MealShow.Model -> Maybe Bool
unitOpenOf model =
    case model of
        MealShow.Loaded loaded ->
            case loaded.nutrition of
                NutritionLoaded input _ ->
                    Just input.unitOpen

                NutritionLoading input ->
                    Just input.unitOpen

                NutritionFailed input _ ->
                    Just input.unitOpen

                NutritionUnavailable input ->
                    Just input.unitOpen

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
