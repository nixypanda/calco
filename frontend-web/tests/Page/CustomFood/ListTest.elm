module Page.CustomFood.ListTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.List as CustomFoodList
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.List"
        [ test "init requests foods" <|
            \_ ->
                CustomFoodList.init
                    |> Tuple.second
                    |> Expect.equal CustomFoodList.RequestFoods
        , test "load success stores foods" <|
            \_ ->
                CustomFoodList.update
                    (CustomFoodList.FoodsLoaded (Ok { items = [] }))
                    (Tuple.first CustomFoodList.init)
                    |> first
                    |> foodsOf
                    |> Expect.equal (Just [])
        , test "load failure stores error" <|
            \_ ->
                CustomFoodList.update
                    (CustomFoodList.FoodsLoaded (Err Client.NetworkError))
                    (Tuple.first CustomFoodList.init)
                    |> first
                    |> errorOf
                    |> Expect.equal (Just "Network error")
        , test "open food navigates to food detail" <|
            \_ ->
                CustomFoodList.update
                    (CustomFoodList.OpenFoodClicked "food-1")
                    (Tuple.first CustomFoodList.init)
                    |> third
                    |> Expect.equal (CustomFoodList.Navigate (CustomFoodShow "food-1"))
        , test "create food navigates to custom food create" <|
            \_ ->
                CustomFoodList.update
                    CustomFoodList.CreateCustomFoodClicked
                    (Tuple.first CustomFoodList.init)
                    |> third
                    |> Expect.equal (CustomFoodList.Navigate CustomFoodCreate)
        , test "back navigates to diary" <|
            \_ ->
                CustomFoodList.update CustomFoodList.BackClicked (Tuple.first CustomFoodList.init)
                    |> third
                    |> Expect.equal (CustomFoodList.Navigate (DiaryDay Nothing))
        , test "food summary omits brand and kcal when missing" <|
            \_ ->
                CustomFoodList.foodSummaryText food
                    |> Expect.equal ""
        , test "food summary shows brand and kcal when present" <|
            \_ ->
                CustomFoodList.foodSummaryText
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


foodsOf : CustomFoodList.Model -> Maybe (List ProductDetail)
foodsOf model =
    case model of
        CustomFoodList.Loaded foods ->
            Just foods

        _ ->
            Nothing


errorOf : CustomFoodList.Model -> Maybe String
errorOf model =
    case model of
        CustomFoodList.LoadFailed message ->
            Just message

        CustomFoodList.Loaded _ ->
            Nothing

        CustomFoodList.Loading ->
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
