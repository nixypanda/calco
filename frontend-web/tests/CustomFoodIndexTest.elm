module CustomFoodIndexTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Index as CustomFoods
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Index"
        [ test "init requests foods" <|
            \_ ->
                CustomFoods.init
                    |> Tuple.second
                    |> Expect.equal CustomFoods.RequestFoods
        , test "load success stores foods" <|
            \_ ->
                CustomFoods.update
                    (CustomFoods.FoodsLoaded (Ok { items = [] }))
                    (Tuple.first CustomFoods.init)
                    |> first
                    |> foodsOf
                    |> Expect.equal (Just [])
        , test "load failure stores error" <|
            \_ ->
                CustomFoods.update
                    (CustomFoods.FoodsLoaded (Err Client.NetworkError))
                    (Tuple.first CustomFoods.init)
                    |> first
                    |> errorOf
                    |> Expect.equal (Just "Network error")
        , test "open food navigates to food detail" <|
            \_ ->
                CustomFoods.update
                    (CustomFoods.OpenFoodClicked "food-1")
                    (Tuple.first CustomFoods.init)
                    |> third
                    |> Expect.equal (CustomFoods.Navigate (FoodDetail "food-1" Nothing))
        , test "edit food navigates to custom food edit" <|
            \_ ->
                CustomFoods.update
                    (CustomFoods.EditFoodClicked "food-1")
                    (Tuple.first CustomFoods.init)
                    |> third
                    |> Expect.equal (CustomFoods.Navigate (CustomFoodEdit "food-1"))
        , test "delete food requests delete" <|
            \_ ->
                CustomFoods.update
                    (CustomFoods.FoodsLoaded (Ok { items = [ food ] }))
                    (Tuple.first CustomFoods.init)
                    |> first
                    |> CustomFoods.update (CustomFoods.DeleteFoodClicked "food-1")
                    |> third
                    |> Expect.equal (CustomFoods.RequestDeleteFood "food-1")
        , test "create food navigates to custom food create" <|
            \_ ->
                CustomFoods.update
                    CustomFoods.CreateCustomFoodClicked
                    (Tuple.first CustomFoods.init)
                    |> third
                    |> Expect.equal (CustomFoods.Navigate CustomFoodCreate)
        , test "back navigates to diary" <|
            \_ ->
                CustomFoods.update CustomFoods.BackClicked (Tuple.first CustomFoods.init)
                    |> third
                    |> Expect.equal (CustomFoods.Navigate (Diary Nothing))
        , test "delete success removes the food" <|
            \_ ->
                let
                    ( loaded, _, _ ) =
                        CustomFoods.update
                            (CustomFoods.FoodsLoaded (Ok { items = [ food, otherFood ] }))
                            (Tuple.first CustomFoods.init)

                    ( deleting, _, _ ) =
                        CustomFoods.update (CustomFoods.DeleteFoodClicked "food-1") loaded

                    ( afterDelete, _, _ ) =
                        CustomFoods.update
                            (CustomFoods.DeleteCompleted "food-1" (Ok ()))
                            deleting
                in
                foodsOf afterDelete
                    |> Expect.equal (Just [ otherFood ])
        , test "food summary omits brand and kcal when missing" <|
            \_ ->
                CustomFoods.foodSummaryText food
                    |> Expect.equal ""
        , test "food summary shows brand and kcal when present" <|
            \_ ->
                CustomFoods.foodSummaryText
                    { food
                        | brand = Just "Local"
                        , nutritionSummary =
                            { per100g =
                                { energyKcal = Just "120"
                                , proteinG = Nothing
                                , carbsG = Nothing
                                , fatG = Nothing
                                , fiberG = Nothing
                                }
                            , perServing = Nothing
                            }
                    }
                    |> Expect.equal "Local ⋅ 120 kcal per 100 g"
        ]


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


foodsOf : CustomFoods.Model -> Maybe (List ProductDetail)
foodsOf model =
    case model of
        CustomFoods.Loaded loaded ->
            Just loaded.foods

        _ ->
            Nothing


errorOf : CustomFoods.Model -> Maybe String
errorOf model =
    case model of
        CustomFoods.LoadFailed message ->
            Just message

        CustomFoods.Loaded { action } ->
            case action of
                CustomFoods.DeleteFailed message ->
                    Just message

                _ ->
                    Nothing

        CustomFoods.Loading ->
            Nothing


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Paneer"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , servingSizeG = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


otherFood : ProductDetail
otherFood =
    { food | id = "food-2", name = "Curd" }
